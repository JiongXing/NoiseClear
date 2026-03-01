//
//  AVPlayerDenoiseTapProcessor.swift
//  VoiceClear
//
//  AVPlayerItem audio tap based RNNoise processing.
//

import AVFoundation
import Foundation
import MediaToolbox

final class AVPlayerDenoiseTapProcessor {

    private let stateLock = NSLock()
    private var strength: Float = 1.0
    private var enabled = true
    private var processor: RNNoiseProcessor?

    private var inputFrame = [Float](repeating: 0, count: RNNoiseProcessor.frameSize)
    private var outputFrame = [Float](repeating: 0, count: RNNoiseProcessor.frameSize)
    private var tapSampleRate: Double = 0
    private var previousOutputTail: Float = 0
    private var rnPendingSamples: [Float] = []
    private var sourcePendingSamples: [Float] = []

    private var sourceFormat: AVAudioFormat?
    private var toRNConverter: AVAudioConverter?
    private var fromRNConverter: AVAudioConverter?

    private static let rnFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: RNNoiseProcessor.sampleRate,
        channels: 1,
        interleaved: false
    )!

    init(strength: Float, enabled: Bool) {
        self.strength = max(0, min(1, strength))
        self.enabled = enabled
        self.processor = try? RNNoiseProcessor()
    }

    deinit {
        processor?.close()
        processor = nil
    }

    func updateStrength(_ value: Float) {
        stateLock.lock()
        strength = max(0, min(1, value))
        stateLock.unlock()
    }

    func setEnabled(_ isEnabled: Bool) {
        stateLock.lock()
        enabled = isEnabled
        stateLock.unlock()
    }

    func attach(to item: AVPlayerItem) async throws {
        let tracks: [AVAssetTrack]
        do {
            tracks = try await item.asset.loadTracks(withMediaType: .audio)
        } catch {
            throw error
        }
        guard let audioTrack = tracks.first else {
            throw NSError(domain: "AVPlayerDenoiseTapProcessor", code: -1, userInfo: [
                NSLocalizedDescriptionKey: L10n.string(.serviceErrorAudioTapNoTrack)
            ])
        }

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            init: { tap, clientInfo, tapStorageOut in
                tapInit(tap: tap, clientInfo: clientInfo, tapStorageOut: tapStorageOut)
            },
            finalize: { tap in
                tapFinalize(tap: tap)
            },
            prepare: { tap, maxFrames, processingFormat in
                tapPrepare(tap: tap, maxFrames: maxFrames, processingFormat: processingFormat)
            },
            unprepare: { tap in
                tapUnprepare(tap: tap)
            },
            process: { tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut in
                tapProcess(
                    tap: tap,
                    numberFrames: numberFrames,
                    flags: flags,
                    bufferListInOut: bufferListInOut,
                    numberFramesOut: numberFramesOut,
                    flagsOut: flagsOut
                )
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )
        guard status == noErr, let tap else {
            throw NSError(domain: "AVPlayerDenoiseTapProcessor", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: L10n.string(.serviceErrorAudioTapCreateFailed)
            ])
        }

        let params = AVMutableAudioMixInputParameters(track: audioTrack)
        params.audioTapProcessor = tap
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [params]
        item.audioMix = audioMix
    }

    fileprivate func processAudioList(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        guard frameCount > 0 else { return }
        stateLock.lock()
        let shouldProcess = enabled
        let localStrength = strength
        let localProcessor = processor
        stateLock.unlock()
        guard shouldProcess, let localProcessor else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard !buffers.isEmpty else { return }
        let scale: Float = 32_768
        let invScale: Float = 1.0 / 32_768

        // 统一转为 mono 做 RNNoise，再写回各声道。
        var mono = [Float](repeating: 0, count: frameCount)
        if buffers.count == 1, buffers[0].mNumberChannels > 1 {
            // interleaved
            let channels = Int(buffers[0].mNumberChannels)
            guard let data = buffers[0].mData else { return }
            let ptr = data.bindMemory(to: Float.self, capacity: frameCount * channels)
            for i in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channels { sum += ptr[i * channels + ch] }
                mono[i] = sum / Float(channels)
            }
        } else {
            // non-interleaved
            for ch in 0..<buffers.count {
                guard let data = buffers[ch].mData else { continue }
                let ptr = data.bindMemory(to: Float.self, capacity: frameCount)
                for i in 0..<frameCount {
                    mono[i] += ptr[i]
                }
            }
            let scaleDown = 1.0 / Float(buffers.count)
            for i in 0..<frameCount { mono[i] *= scaleDown }
        }

        var denoised = mono
        if tapSampleRate > 0, abs(tapSampleRate - RNNoiseProcessor.sampleRate) > 1 {
            denoised = processResampled(
                mono: mono,
                localProcessor: localProcessor,
                localStrength: localStrength
            )
        } else {
            var offset = 0
            while offset < frameCount {
                let current = min(RNNoiseProcessor.frameSize, frameCount - offset)
                for i in 0..<current { inputFrame[i] = mono[offset + i] * scale }
                if current < RNNoiseProcessor.frameSize {
                    for i in current..<RNNoiseProcessor.frameSize { inputFrame[i] = 0 }
                }
                localProcessor.processFrame(output: &outputFrame, input: &inputFrame)
                for i in 0..<current {
                    let clean = outputFrame[i] * invScale
                    denoised[offset + i] = mono[offset + i] * (1 - localStrength) + clean * localStrength
                }
                offset += RNNoiseProcessor.frameSize
            }
        }

        if !denoised.isEmpty {
            applyBoundarySmoothingIfNeeded(&denoised)
        }
        if let tail = denoised.last {
            previousOutputTail = tail
        }

        if buffers.count == 1, buffers[0].mNumberChannels > 1 {
            let channels = Int(buffers[0].mNumberChannels)
            guard let data = buffers[0].mData else { return }
            let ptr = data.bindMemory(to: Float.self, capacity: frameCount * channels)
            for i in 0..<frameCount {
                let v = denoised[i]
                for ch in 0..<channels {
                    ptr[i * channels + ch] = v
                }
            }
        } else {
            for ch in 0..<buffers.count {
                guard let data = buffers[ch].mData else { continue }
                let ptr = data.bindMemory(to: Float.self, capacity: frameCount)
                for i in 0..<frameCount { ptr[i] = denoised[i] }
            }
        }
    }

    fileprivate func handleTapPrepare(
        maxFrames: CMItemCount,
        processingFormat: UnsafePointer<AudioStreamBasicDescription>
    ) {
        tapSampleRate = processingFormat.pointee.mSampleRate
        sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: tapSampleRate,
            channels: 1,
            interleaved: false
        )
        if let sourceFormat {
            toRNConverter = AVAudioConverter(from: sourceFormat, to: Self.rnFormat)
            fromRNConverter = AVAudioConverter(from: Self.rnFormat, to: sourceFormat)
        } else {
            toRNConverter = nil
            fromRNConverter = nil
        }
        previousOutputTail = 0
        rnPendingSamples.removeAll(keepingCapacity: true)
        sourcePendingSamples.removeAll(keepingCapacity: true)
    }

    private func processResampled(
        mono: [Float],
        localProcessor: RNNoiseProcessor,
        localStrength: Float
    ) -> [Float] {
        guard let sourceFormat,
              let toRNConverter,
              let fromRNConverter
        else { return mono }

        guard let srcBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(mono.count)
        ) else { return mono }
        srcBuffer.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { ptr in
            srcBuffer.floatChannelData?[0].update(from: ptr.baseAddress!, count: mono.count)
        }

        let upRatio = RNNoiseProcessor.sampleRate / sourceFormat.sampleRate
        let upCapacity = AVAudioFrameCount(Double(mono.count) * upRatio) + 64
        guard let rnBuffer = convert(input: srcBuffer, converter: toRNConverter, outputCapacity: upCapacity) else {
            return mono
        }
        guard let rnData = rnBuffer.floatChannelData?[0] else { return mono }
        let rnCount = Int(rnBuffer.frameLength)
        if rnCount == 0 { return mono }

        var rnInput = rnPendingSamples
        rnInput.reserveCapacity(rnPendingSamples.count + rnCount)
        rnInput.append(contentsOf: UnsafeBufferPointer(start: rnData, count: rnCount))

        let processableCount = (rnInput.count / RNNoiseProcessor.frameSize) * RNNoiseProcessor.frameSize
        let carryCount = rnInput.count - processableCount
        if processableCount == 0 {
            rnPendingSamples = rnInput
            return mono
        }

        var rnProcessed = [Float](repeating: 0, count: processableCount)
        let scale: Float = 32_768
        let invScale: Float = 1.0 / 32_768
        var offset = 0
        while offset < processableCount {
            for i in 0..<RNNoiseProcessor.frameSize { inputFrame[i] = rnInput[offset + i] * scale }
            localProcessor.processFrame(output: &outputFrame, input: &inputFrame)
            for i in 0..<RNNoiseProcessor.frameSize {
                let clean = outputFrame[i] * invScale
                rnProcessed[offset + i] = rnInput[offset + i] * (1 - localStrength) + clean * localStrength
            }
            offset += RNNoiseProcessor.frameSize
        }
        if carryCount > 0 {
            rnPendingSamples = Array(rnInput.suffix(carryCount))
        } else {
            rnPendingSamples.removeAll(keepingCapacity: true)
        }

        guard let rnOutBuffer = AVAudioPCMBuffer(
            pcmFormat: Self.rnFormat,
            frameCapacity: AVAudioFrameCount(rnProcessed.count)
        ) else { return mono }
        rnOutBuffer.frameLength = AVAudioFrameCount(rnProcessed.count)
        rnProcessed.withUnsafeBufferPointer { ptr in
            rnOutBuffer.floatChannelData?[0].update(from: ptr.baseAddress!, count: rnProcessed.count)
        }

        let downRatio = sourceFormat.sampleRate / RNNoiseProcessor.sampleRate
        let downCapacity = AVAudioFrameCount(Double(rnProcessed.count) * downRatio) + 64
        guard let dstBuffer = convert(input: rnOutBuffer, converter: fromRNConverter, outputCapacity: downCapacity),
              let dstData = dstBuffer.floatChannelData?[0]
        else { return mono }

        let downFrameLength = Int(dstBuffer.frameLength)
        if downFrameLength > 0 {
            sourcePendingSamples.append(contentsOf: UnsafeBufferPointer(start: dstData, count: downFrameLength))
        }

        // 使用跨回调的 pending 队列按“原始帧数”精确取样，避免每包线性重映射引入拖音/重音。
        if sourcePendingSamples.count >= mono.count {
            let output = Array(sourcePendingSamples.prefix(mono.count))
            sourcePendingSamples.removeFirst(mono.count)
            return output
        }

        // 数据不足时只对缺口做原始音频回填，避免重复拉伸造成的重音。
        var output = sourcePendingSamples
        sourcePendingSamples.removeAll(keepingCapacity: true)
        if output.count < mono.count {
            output.append(contentsOf: mono.suffix(mono.count - output.count))
        }
        return output
    }

    private func convert(
        input: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        outputCapacity: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        guard let output = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: outputCapacity
        ) else { return nil }
        var done = false
        var err: NSError?
        converter.convert(to: output, error: &err) { _, status in
            if done {
                status.pointee = .noDataNow
                return nil
            }
            done = true
            status.pointee = .haveData
            return input
        }
        if err != nil { return nil }
        return output
    }

    private func applyBoundarySmoothingIfNeeded(_ samples: inout [Float]) {
        guard !samples.isEmpty else { return }
        let head = samples[0]
        let jump = abs(head - previousOutputTail)
        let smoothingThreshold: Float = 0.01
        guard jump > smoothingThreshold else { return }

        let fadeCount = min(96, samples.count)
        let from = previousOutputTail
        for i in 0..<fadeCount {
            let t = Float(i + 1) / Float(fadeCount)
            let target = samples[i]
            samples[i] = from * (1 - t) + target * t
        }
    }
}

// MARK: - Tap callbacks

private func tapInit(
    tap: MTAudioProcessingTap,
    clientInfo: UnsafeMutableRawPointer?,
    tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    tapStorageOut.pointee = clientInfo
}

private func tapFinalize(tap: MTAudioProcessingTap) {}

private func tapPrepare(
    tap: MTAudioProcessingTap,
    maxFrames: CMItemCount,
    processingFormat: UnsafePointer<AudioStreamBasicDescription>
) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    let owner = Unmanaged<AVPlayerDenoiseTapProcessor>.fromOpaque(storage).takeUnretainedValue()
    owner.handleTapPrepare(maxFrames: maxFrames, processingFormat: processingFormat)
}

private func tapUnprepare(tap: MTAudioProcessingTap) {}

private func tapProcess(
    tap: MTAudioProcessingTap,
    numberFrames: CMItemCount,
    flags: MTAudioProcessingTapFlags,
    bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    var localFlags: MTAudioProcessingTapFlags = 0
    var timeRange = CMTimeRange()
    let status = MTAudioProcessingTapGetSourceAudio(
        tap,
        numberFrames,
        bufferListInOut,
        &localFlags,
        &timeRange,
        numberFramesOut
    )
    guard status == noErr else { return }
    flagsOut.pointee = localFlags

    let storage = MTAudioProcessingTapGetStorage(tap)
    let owner = Unmanaged<AVPlayerDenoiseTapProcessor>.fromOpaque(storage).takeUnretainedValue()
    owner.processAudioList(bufferListInOut, frameCount: Int(numberFramesOut.pointee))
}
