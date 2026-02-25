//
//  IncrementalStreamingDenoiser.swift
//  VoiceClear
//
//  Incremental AVFoundation + RNNoise streaming pipeline.
//

import AVFoundation
import Foundation

/// 真流式实现：增量解码 + RNNoise + 内存环形队列（队列化实现）。
final class IncrementalStreamingDenoiser: StreamingAudioPipeline, @unchecked Sendable {

    private let queueLock = NSCondition()
    private var bufferQueue: [AVAudioPCMBuffer] = []
    private var queuedFrames: Int = 0
    private let maxQueuedFrames = Int(StreamingDenoiser.sampleRate * 2.0) // 约 2 秒

    private var workerQueue: DispatchQueue?
    private var running = false
    private var reachedEOF = false

    private var denoiseStrength: Float = 1.0
    private var enableDenoise: Bool = true
    private var denoiseMetricLogCount = 0

    var isRunning: Bool {
        queueLock.lock()
        defer { queueLock.unlock() }
        return running
    }

    var playbackFormat: AVAudioFormat {
        StreamingDenoiser.outputFormat
    }

    func start(
        inputURL: URL,
        strength: Float,
        startTime: TimeInterval,
        maxDuration: TimeInterval?,
        isVideo: Bool
    ) throws {
        stop()
        queueLock.lock()
        running = true
        reachedEOF = false
        denoiseStrength = max(0, min(1, strength))
        enableDenoise = true
        denoiseMetricLogCount = 0
        queueLock.unlock()
        // #region agent log
        DebugRuntimeLogger.log(
            runId: "run-voice-quality",
            hypothesisId: "H1",
            location: "IncrementalStreamingDenoiser.start",
            message: "incremental denoise start",
            data: [
                "strength": denoiseStrength,
                "startTime": startTime,
                "isVideo": isVideo
            ]
        )
        // #endregion
        launchWorker(inputURL: inputURL, startTime: startTime, maxDuration: maxDuration, isVideo: isVideo)
    }

    func startOriginal(
        inputURL: URL,
        startTime: TimeInterval,
        maxDuration: TimeInterval?,
        isVideo: Bool
    ) throws {
        stop()
        queueLock.lock()
        running = true
        reachedEOF = false
        denoiseStrength = 0
        enableDenoise = false
        denoiseMetricLogCount = 0
        queueLock.unlock()
        launchWorker(inputURL: inputURL, startTime: startTime, maxDuration: maxDuration, isVideo: isVideo)
    }

    func readNextBuffer() -> AVAudioPCMBuffer? {
        queueLock.lock()
        defer { queueLock.unlock() }
        if !bufferQueue.isEmpty {
            let buffer = bufferQueue.removeFirst()
            queuedFrames = max(0, queuedFrames - Int(buffer.frameLength))
            queueLock.signal()
            return buffer
        }
        if reachedEOF || !running {
            return nil
        }
        return nil
    }

    func stop() {
        queueLock.lock()
        running = false
        reachedEOF = true
        bufferQueue.removeAll()
        queuedFrames = 0
        queueLock.broadcast()
        queueLock.unlock()
        workerQueue = nil
    }

    // MARK: - Worker

    private func launchWorker(
        inputURL: URL,
        startTime: TimeInterval,
        maxDuration: TimeInterval?,
        isVideo: Bool
    ) {
        let queue = DispatchQueue(label: "com.voiceclear.incremental.pipeline", qos: .userInitiated)
        workerQueue = queue
        queue.async { [weak self] in
            guard let self else { return }
            do {
                if isVideo {
                    try self.produceVideoBuffers(
                        inputURL: inputURL,
                        startTime: startTime,
                        maxDuration: maxDuration
                    )
                } else {
                    try self.produceAudioBuffers(
                        inputURL: inputURL,
                        startTime: startTime,
                        maxDuration: maxDuration
                    )
                }
            } catch {
                self.stop()
            }
            self.queueLock.lock()
            self.reachedEOF = true
            self.running = false
            self.queueLock.broadcast()
            self.queueLock.unlock()
        }
    }

    private func produceAudioBuffers(
        inputURL: URL,
        startTime: TimeInterval,
        maxDuration: TimeInterval?
    ) throws {
        let inputFile = try AVAudioFile(forReading: inputURL)
        let inputFormat = inputFile.processingFormat
        let inputSampleRate = inputFormat.sampleRate

        let startFrame = AVAudioFramePosition(startTime * inputSampleRate)
        if startFrame > 0 && startFrame < inputFile.length {
            inputFile.framePosition = startFrame
        }

        let remainingFrames = AVAudioFrameCount(max(0, inputFile.length - inputFile.framePosition))
        let maxFrames: AVAudioFrameCount
        if let maxDuration, maxDuration > 0 {
            maxFrames = min(AVAudioFrameCount(maxDuration * inputSampleRate), remainingFrames)
        } else {
            maxFrames = remainingFrames
        }
        if maxFrames == 0 { return }

        let targetFormat = enableDenoise
            ? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
            : StreamingDenoiser.outputFormat

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw StreamingDenoiserError.conversionFailed("无法创建增量转换器")
        }

        let readChunkFrames: AVAudioFrameCount = 2048
        var producedInputFrames: AVAudioFrameCount = 0
        let rnnoise = try RNNoiseProcessor()
        defer { rnnoise.close() }

        while isRunning, producedInputFrames < maxFrames {
            let request = min(readChunkFrames, maxFrames - producedInputFrames)
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: request) else { break }
            try inputFile.read(into: inputBuffer, frameCount: request)
            if inputBuffer.frameLength == 0 { break }
            producedInputFrames += inputBuffer.frameLength

            let ratio = targetFormat.sampleRate / inputSampleRate
            let outCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 64
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { continue }

            var done = false
            var convError: NSError?
            converter.convert(to: converted, error: &convError) { _, outStatus in
                if done {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                done = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
            if convError != nil || converted.frameLength == 0 { continue }

            let output = enableDenoise
                ? self.buildStereoDenoisedBuffer(fromMono: converted, processor: rnnoise, strength: denoiseStrength)
                : converted
            try enqueue(output)
        }
    }

    private func produceVideoBuffers(
        inputURL: URL,
        startTime: TimeInterval,
        maxDuration: TimeInterval?
    ) throws {
        let asset = AVURLAsset(url: inputURL)
        let audioTrack: AVAssetTrack
        do {
            audioTrack = try AVAssetAsyncLoader.firstTrack(of: asset, mediaType: .audio)
        } catch {
            throw StreamingDenoiserError.conversionFailed(error.localizedDescription)
        }

        let reader = try AVAssetReader(asset: asset)
        let start = CMTime(seconds: startTime, preferredTimescale: 48_000)
        let duration = maxDuration.map { CMTime(seconds: $0, preferredTimescale: 48_000) } ?? CMTime.positiveInfinity
        reader.timeRange = CMTimeRange(start: start, duration: duration)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: enableDenoise ? 1 : 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw StreamingDenoiserError.conversionFailed(reader.error?.localizedDescription ?? "视频增量读取失败")
        }

        let rnnoise = try RNNoiseProcessor()
        defer { rnnoise.close() }

        while isRunning, reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(
                block,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &dataPointer
            )
            guard let dataPointer, length > 0 else { continue }

            let floatCount = length / MemoryLayout<Float>.size
            let floatPtr = UnsafeRawPointer(dataPointer).bindMemory(to: Float.self, capacity: floatCount)
            let samples = Array(UnsafeBufferPointer(start: floatPtr, count: floatCount))

            let pcmBuffer: AVAudioPCMBuffer?
            if enableDenoise {
                pcmBuffer = buildStereoDenoisedBuffer(fromMonoSamples: samples, processor: rnnoise, strength: denoiseStrength)
            } else {
                pcmBuffer = buildStereoPassthroughBuffer(fromInterleavedSamples: samples, channelCount: 2)
            }
            if let pcmBuffer {
                try enqueue(pcmBuffer)
            }
        }
    }

    // MARK: - Buffer Helpers

    private func enqueue(_ buffer: AVAudioPCMBuffer) throws {
        queueLock.lock()
        defer { queueLock.unlock() }
        while running && queuedFrames >= maxQueuedFrames {
            queueLock.wait(until: Date().addingTimeInterval(0.05))
        }
        guard running else { return }
        bufferQueue.append(buffer)
        queuedFrames += Int(buffer.frameLength)
        queueLock.signal()
    }

    private func buildStereoDenoisedBuffer(
        fromMono monoBuffer: AVAudioPCMBuffer,
        processor: RNNoiseProcessor,
        strength: Float
    ) -> AVAudioPCMBuffer {
        guard let monoData = monoBuffer.floatChannelData?[0] else {
            return monoToStereoSilent(frameCount: Int(monoBuffer.frameLength))
        }
        let samples = Array(UnsafeBufferPointer(start: monoData, count: Int(monoBuffer.frameLength)))
        return buildStereoDenoisedBuffer(fromMonoSamples: samples, processor: processor, strength: strength)
    }

    private func buildStereoDenoisedBuffer(
        fromMonoSamples monoSamples: [Float],
        processor: RNNoiseProcessor,
        strength: Float
    ) -> AVAudioPCMBuffer {
        let frameSize = RNNoiseProcessor.frameSize
        let clippedStrength = max(0, min(1, strength))
        let scale: Float = 32_768
        let invScale: Float = 1.0 / 32_768
        var processed = [Float](repeating: 0, count: monoSamples.count)

        var inputFrame = [Float](repeating: 0, count: frameSize)
        var outputFrame = [Float](repeating: 0, count: frameSize)
        var offset = 0

        while offset < monoSamples.count {
            let current = min(frameSize, monoSamples.count - offset)
            for i in 0..<current { inputFrame[i] = monoSamples[offset + i] * scale }
            if current < frameSize {
                for i in current..<frameSize { inputFrame[i] = 0 }
            }
            processor.processFrame(output: &outputFrame, input: &inputFrame)
            for i in 0..<current {
                let denoised = outputFrame[i] * invScale
                processed[offset + i] = monoSamples[offset + i] * (1 - clippedStrength) + denoised * clippedStrength
            }
            offset += frameSize
        }

        if denoiseMetricLogCount < 3 {
            denoiseMetricLogCount += 1
            // #region agent log
            DebugRuntimeLogger.log(
                runId: "run-voice-quality",
                hypothesisId: "H3",
                location: "IncrementalStreamingDenoiser.buildStereoDenoisedBuffer",
                message: "denoise buffer metrics",
                data: [
                    "strength": clippedStrength,
                    "inputRMS": rms(of: monoSamples),
                    "outputRMS": rms(of: processed),
                    "inputPeak": peak(of: monoSamples),
                    "outputPeak": peak(of: processed),
                    "sampleCount": monoSamples.count
                ]
            )
            // #endregion
        }

        let frameCount = processed.count
        guard let stereo = AVAudioPCMBuffer(
            pcmFormat: StreamingDenoiser.outputFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return monoToStereoSilent(frameCount: frameCount)
        }
        stereo.frameLength = AVAudioFrameCount(frameCount)
        if let channels = stereo.floatChannelData {
            processed.withUnsafeBufferPointer { ptr in
                channels[0].update(from: ptr.baseAddress!, count: frameCount)
                channels[1].update(from: ptr.baseAddress!, count: frameCount)
            }
        }
        return stereo
    }

    private func buildStereoPassthroughBuffer(
        fromInterleavedSamples samples: [Float],
        channelCount: Int
    ) -> AVAudioPCMBuffer? {
        guard channelCount > 0 else { return nil }
        let frameCount = samples.count / channelCount
        guard frameCount > 0 else { return nil }
        guard let stereo = AVAudioPCMBuffer(
            pcmFormat: StreamingDenoiser.outputFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return nil
        }
        stereo.frameLength = AVAudioFrameCount(frameCount)
        guard let channels = stereo.floatChannelData else { return stereo }

        if channelCount == 1 {
            for i in 0..<frameCount {
                let v = samples[i]
                channels[0][i] = v
                channels[1][i] = v
            }
            return stereo
        }

        for i in 0..<frameCount {
            channels[0][i] = samples[i * channelCount]
            channels[1][i] = samples[i * channelCount + 1]
        }
        return stereo
    }

    private func monoToStereoSilent(frameCount: Int) -> AVAudioPCMBuffer {
        let safeCount = max(1, frameCount)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: StreamingDenoiser.outputFormat,
            frameCapacity: AVAudioFrameCount(safeCount)
        )!
        buffer.frameLength = AVAudioFrameCount(safeCount)
        if let channels = buffer.floatChannelData {
            memset(channels[0], 0, safeCount * MemoryLayout<Float>.size)
            memset(channels[1], 0, safeCount * MemoryLayout<Float>.size)
        }
        return buffer
    }

    private func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sum / Float(samples.count))
    }

    private func peak(of samples: [Float]) -> Float {
        samples.reduce(Float(0)) { max($0, abs($1)) }
    }
}

