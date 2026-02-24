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

    func attach(to item: AVPlayerItem) throws {
        let audioTrack = try AVAssetAsyncLoader.firstTrack(of: item.asset, mediaType: .audio)

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess
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
                NSLocalizedDescriptionKey: "无法创建音频处理 Tap"
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
) {}

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

