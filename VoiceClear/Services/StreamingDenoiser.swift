//
//  StreamingDenoiser.swift
//  VoiceClear
//
//  Created by jxing on 2026/2/15.
//

import AVFoundation
import Foundation

// MARK: - 流式降噪引擎

/// 基于 AVFoundation + RNNoise 的流式降噪引擎（跨平台统一实现）
///
/// 工作流程:
/// 1. `start()` 解码指定区间的音频 → RNNoise 降噪 → 存入内存 PCMBuffer
/// 2. `readNextBuffer()` 从内存中按固定帧数切片返回，供 AVAudioEngine 播放
/// 3. `stop()` 释放内存缓冲
///
/// 由 PlayerViewModel 管理分段 (chunk) 调用：每段约 4 秒，播放完一段后启动下一段。
final class StreamingDenoiser: StreamingAudioPipeline, @unchecked Sendable {

    // MARK: - 常量

    /// 输出采样率（播放质量优先）
    static let sampleRate: Double = 48000.0

    /// 输出声道数（双声道立体声）
    static let channels: UInt32 = 2

    /// 每次读取的帧数（4096 帧 ≈ 85ms @48kHz）
    static let bufferFrameCount: AVAudioFrameCount = 4096

    /// 每帧字节数：channels x sizeof(Float32)
    static var bytesPerFrame: Int {
        Int(channels) * MemoryLayout<Float>.size
    }

    /// 每次读取的字节数
    static var readSize: Int {
        Int(bufferFrameCount) * bytesPerFrame
    }

    /// 输出音频格式（非交错，AVAudioEngine 要求）
    static var outputFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
    }

    /// RNNoise 处理要求的采样率（48kHz 单声道）
    private static let rnnoiseMonoFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48000.0,
        channels: 1,
        interleaved: false
    )!

    // MARK: - 状态

    /// 是否已启动
    private(set) var isRunning: Bool = false

    /// 处理后的音频数据缓冲（48kHz 双声道非交错）
    private var processedBuffer: AVAudioPCMBuffer?

    /// 当前读取位置（帧）
    private var readPosition: AVAudioFrameCount = 0

    /// 线程安全锁
    private let lock = NSLock()

    // MARK: - 初始化

    init() {}

    deinit {
        stop()
    }

    var playbackFormat: AVAudioFormat {
        Self.outputFormat
    }

    // MARK: - 启动流式降噪

    /// 启动流式降噪
    /// - Parameters:
    ///   - inputURL: 输入媒体文件
    ///   - strength: 降噪强度 (0.0 ~ 1.0)
    ///   - startTime: 起始播放时间（秒），用于 seek
    ///   - maxDuration: 最大处理时长（秒）
    ///   - isVideo: 是否为视频文件
    func start(
        inputURL: URL,
        strength: Float,
        startTime: TimeInterval = 0,
        maxDuration: TimeInterval? = nil,
        isVideo: Bool = false
    ) throws {
        stop()

        // 1. 解码为 48kHz 单声道
        let monoBuffer: AVAudioPCMBuffer
        if isVideo {
            monoBuffer = try decodeVideoAudioToMono(
                inputURL: inputURL, startTime: startTime, maxDuration: maxDuration
            )
        } else {
            monoBuffer = try decodeAudioToMono(
                inputURL: inputURL, startTime: startTime, maxDuration: maxDuration
            )
        }

        guard let monoData = monoBuffer.floatChannelData?[0] else {
            throw StreamingDenoiserError.conversionFailed(L10n.string(.serviceErrorReadMonoDataFailed))
        }
        let sampleCount = Int(monoBuffer.frameLength)
        guard sampleCount > 0 else {
            throw StreamingDenoiserError.conversionFailed(L10n.string(.serviceErrorDecodedDataEmpty))
        }

        // 2. RNNoise 逐帧降噪
        let denoisedMono = try denoiseMonoSamples(
            monoData, count: sampleCount, strength: strength
        )

        // 3. 单声道 → 双声道，存入内存缓冲
        let stereoBuffer = try monoToStereoBuffer(denoisedMono, count: sampleCount)

        lock.lock()
        self.processedBuffer = stereoBuffer
        self.readPosition = 0
        self.isRunning = true
        lock.unlock()
    }

    // MARK: - 启动原始播放（不降噪）

    /// 启动原始音频输出（不应用降噪滤镜）
    func startOriginal(
        inputURL: URL,
        startTime: TimeInterval = 0,
        maxDuration: TimeInterval? = nil,
        isVideo: Bool = false
    ) throws {
        stop()

        // 解码为 48kHz 双声道（不经过 RNNoise）
        let stereoBuffer: AVAudioPCMBuffer
        if isVideo {
            stereoBuffer = try decodeVideoAudioToStereo(
                inputURL: inputURL, startTime: startTime, maxDuration: maxDuration
            )
        } else {
            stereoBuffer = try decodeAudioToStereo(
                inputURL: inputURL, startTime: startTime, maxDuration: maxDuration
            )
        }

        guard stereoBuffer.frameLength > 0 else {
            throw StreamingDenoiserError.conversionFailed(L10n.string(.serviceErrorDecodedDataEmpty))
        }

        lock.lock()
        self.processedBuffer = stereoBuffer
        self.readPosition = 0
        self.isRunning = true
        lock.unlock()
    }

    // MARK: - 读取 PCM 数据

    /// 读取下一个 PCM buffer
    ///
    /// - Returns: 填充好的 AVAudioPCMBuffer，EOF 或出错时返回 nil
    func readNextBuffer() -> AVAudioPCMBuffer? {
        lock.lock()
        guard let source = processedBuffer else {
            lock.unlock()
            return nil
        }
        let pos = readPosition
        lock.unlock()

        let remaining = source.frameLength - pos
        guard remaining > 0 else { return nil }

        let framesToRead = min(Self.bufferFrameCount, remaining)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: framesToRead) else {
            return nil
        }
        buffer.frameLength = framesToRead

        // 从 processedBuffer 的 readPosition 处拷贝 framesToRead 帧
        if let srcChannels = source.floatChannelData,
           let dstChannels = buffer.floatChannelData {
            let byteCount = Int(framesToRead) * MemoryLayout<Float>.size
            for ch in 0..<Int(Self.channels) {
                memcpy(dstChannels[ch], srcChannels[ch].advanced(by: Int(pos)), byteCount)
            }
        }

        lock.lock()
        readPosition += framesToRead
        lock.unlock()

        return buffer
    }

    // MARK: - 停止

    /// 停止并清理资源（线程安全）
    func stop() {
        lock.lock()
        processedBuffer = nil
        readPosition = 0
        isRunning = false
        lock.unlock()
    }

    // MARK: - 音频解码（单声道，用于降噪）

    /// 将纯音频文件解码为 48kHz 单声道
    private func decodeAudioToMono(
        inputURL: URL,
        startTime: TimeInterval,
        maxDuration: TimeInterval?
    ) throws -> AVAudioPCMBuffer {
        let inputFile = try AVAudioFile(forReading: inputURL)
        let inputFormat = inputFile.processingFormat
        let inputSR = inputFormat.sampleRate

        // 跳转到起始位置
        let startFrame = AVAudioFramePosition(startTime * inputSR)
        if startFrame > 0 && startFrame < inputFile.length {
            inputFile.framePosition = startFrame
        }

        // 计算要读取的帧数
        let remaining = AVAudioFrameCount(inputFile.length - inputFile.framePosition)
        let maxFrames: AVAudioFrameCount
        if let maxDur = maxDuration, maxDur > 0 {
            maxFrames = min(AVAudioFrameCount(maxDur * inputSR), remaining)
        } else {
            maxFrames = remaining
        }
        guard maxFrames > 0 else {
            throw StreamingDenoiserError.conversionFailed(L10n.string(.serviceErrorNoReadableAudioFrames))
        }

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: maxFrames) else {
            throw StreamingDenoiserError.conversionFailed(L10n.string(.serviceErrorInputBufferCreationFailed))
        }
        try inputFile.read(into: inputBuffer, frameCount: maxFrames)

        // 转换为 48kHz 单声道
        let monoFormat = Self.rnnoiseMonoFormat
        guard let converter = AVAudioConverter(from: inputFormat, to: monoFormat) else {
            throw StreamingDenoiserError.conversionFailed(L10n.string(.serviceErrorConverterCreationFailed))
        }

        let ratio = RNNoiseProcessor.sampleRate / inputSR
        let outCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 256
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: outCapacity) else {
            throw StreamingDenoiserError.conversionFailed(L10n.string(.serviceErrorOutputBufferCreationFailed))
        }

        var isDone = false
        var convError: NSError?
        converter.convert(to: outputBuffer, error: &convError) { _, outStatus in
            if isDone {
                outStatus.pointee = .noDataNow
                return nil
            }
            isDone = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        if let convError {
            throw StreamingDenoiserError.conversionFailed(convError.localizedDescription)
        }

        return outputBuffer
    }

    /// 从视频文件提取音频并解码为 48kHz 单声道
    private func decodeVideoAudioToMono(
        inputURL: URL,
        startTime: TimeInterval,
        maxDuration: TimeInterval?
    ) throws -> AVAudioPCMBuffer {
        let asset = AVURLAsset(url: inputURL)
        let audioTrack: AVAssetTrack
        do {
            audioTrack = try AVAssetAsyncLoader.firstTrack(of: asset, mediaType: .audio)
        } catch {
            throw StreamingDenoiserError.conversionFailed(error.localizedDescription)
        }

        let reader = try AVAssetReader(asset: asset)
        let start = CMTime(seconds: startTime, preferredTimescale: 48000)
        let dur = maxDuration.map { CMTime(seconds: $0, preferredTimescale: 48000) } ?? CMTime.positiveInfinity
        reader.timeRange = CMTimeRange(start: start, duration: dur)

        let readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: RNNoiseProcessor.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: readerSettings)
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)

        guard reader.startReading() else {
            throw StreamingDenoiserError.conversionFailed(
                reader.error?.localizedDescription ?? L10n.string(.serviceErrorAssetReaderStartFailed)
            )
        }

        // 收集所有采样到数组
        var allSamples = [Float]()
        while reader.status == .reading {
            guard let sampleBuffer = trackOutput.copyNextSampleBuffer() else { break }
            let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
            guard numSamples > 0 else { continue }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
            guard let data = dataPointer else { continue }

            let floatCount = totalLength / MemoryLayout<Float>.size
            let floatPtr = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: floatCount)
            allSamples.append(contentsOf: UnsafeBufferPointer(start: floatPtr, count: floatCount))
        }

        // 转为 AVAudioPCMBuffer
        let monoFormat = Self.rnnoiseMonoFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(allSamples.count)) else {
            throw StreamingDenoiserError.conversionFailed(L10n.string(.serviceErrorMonoBufferCreationFailed))
        }
        buffer.frameLength = AVAudioFrameCount(allSamples.count)
        allSamples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: allSamples.count)
        }

        return buffer
    }

    // MARK: - 音频解码（双声道，用于原始播放）

    /// 将纯音频文件解码为 48kHz 双声道
    private func decodeAudioToStereo(
        inputURL: URL,
        startTime: TimeInterval,
        maxDuration: TimeInterval?
    ) throws -> AVAudioPCMBuffer {
        let inputFile = try AVAudioFile(forReading: inputURL)
        let inputFormat = inputFile.processingFormat
        let inputSR = inputFormat.sampleRate

        let startFrame = AVAudioFramePosition(startTime * inputSR)
        if startFrame > 0 && startFrame < inputFile.length {
            inputFile.framePosition = startFrame
        }

        let remaining = AVAudioFrameCount(inputFile.length - inputFile.framePosition)
        let maxFrames: AVAudioFrameCount
        if let maxDur = maxDuration, maxDur > 0 {
            maxFrames = min(AVAudioFrameCount(maxDur * inputSR), remaining)
        } else {
            maxFrames = remaining
        }
        guard maxFrames > 0 else {
            throw StreamingDenoiserError.conversionFailed(L10n.string(.serviceErrorNoReadableAudioFrames))
        }

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: maxFrames) else {
            throw StreamingDenoiserError.conversionFailed(L10n.string(.serviceErrorInputBufferCreationFailed))
        }
        try inputFile.read(into: inputBuffer, frameCount: maxFrames)

        let stereoFormat = Self.outputFormat
        guard let converter = AVAudioConverter(from: inputFormat, to: stereoFormat) else {
            throw StreamingDenoiserError.conversionFailed(L10n.string(.serviceErrorConverterCreationFailed))
        }

        let ratio = Self.sampleRate / inputSR
        let outCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 256
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: outCapacity) else {
            throw StreamingDenoiserError.conversionFailed(L10n.string(.serviceErrorOutputBufferCreationFailed))
        }

        var isDone = false
        var convError: NSError?
        converter.convert(to: outputBuffer, error: &convError) { _, outStatus in
            if isDone {
                outStatus.pointee = .noDataNow
                return nil
            }
            isDone = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        if let convError {
            throw StreamingDenoiserError.conversionFailed(convError.localizedDescription)
        }

        return outputBuffer
    }

    /// 从视频文件提取音频并解码为 48kHz 双声道
    private func decodeVideoAudioToStereo(
        inputURL: URL,
        startTime: TimeInterval,
        maxDuration: TimeInterval?
    ) throws -> AVAudioPCMBuffer {
        let asset = AVURLAsset(url: inputURL)
        let audioTrack: AVAssetTrack
        do {
            audioTrack = try AVAssetAsyncLoader.firstTrack(of: asset, mediaType: .audio)
        } catch {
            throw StreamingDenoiserError.conversionFailed(error.localizedDescription)
        }

        let reader = try AVAssetReader(asset: asset)
        let start = CMTime(seconds: startTime, preferredTimescale: 48000)
        let dur = maxDuration.map { CMTime(seconds: $0, preferredTimescale: 48000) } ?? CMTime.positiveInfinity
        reader.timeRange = CMTimeRange(start: start, duration: dur)

        // 直接输出 48kHz 双声道
        let readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: Self.channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: readerSettings)
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)

        guard reader.startReading() else {
            throw StreamingDenoiserError.conversionFailed(
                reader.error?.localizedDescription ?? L10n.string(.serviceErrorAssetReaderStartFailed)
            )
        }

        // 读取交错格式数据，转为非交错格式
        let channelCount = Int(Self.channels)
        var interleavedSamples = [Float]()

        while reader.status == .reading {
            guard let sampleBuffer = trackOutput.copyNextSampleBuffer() else { break }
            let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
            guard numSamples > 0 else { continue }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
            guard let data = dataPointer else { continue }

            let floatCount = totalLength / MemoryLayout<Float>.size
            let floatPtr = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: floatCount)
            interleavedSamples.append(contentsOf: UnsafeBufferPointer(start: floatPtr, count: floatCount))
        }

        // 交错 → 非交错
        let frameCount = interleavedSamples.count / channelCount
        guard frameCount > 0 else {
            throw StreamingDenoiserError.conversionFailed(L10n.string(.serviceErrorVideoAudioDecodedEmpty))
        }

        let stereoFormat = Self.outputFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw StreamingDenoiserError.conversionFailed(L10n.string(.serviceErrorStereoBufferCreationFailed))
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        if let channelData = buffer.floatChannelData {
            for frame in 0..<frameCount {
                for ch in 0..<channelCount {
                    channelData[ch][frame] = interleavedSamples[frame * channelCount + ch]
                }
            }
        }

        return buffer
    }

    // MARK: - RNNoise 降噪

    /// 对 48kHz 单声道 PCM 执行 RNNoise 降噪
    ///
    /// RNNoise 期望输入范围为 -32768~32768（int16 浮点表示），
    /// 因此需要先缩放再处理，处理后缩放回 -1.0~1.0 范围。
    private func denoiseMonoSamples(
        _ samples: UnsafePointer<Float>,
        count: Int,
        strength: Float
    ) throws -> [Float] {
        let processor = try RNNoiseProcessor()
        defer { processor.close() }

        let clampedStrength = max(0.0, min(1.0, strength))
        let frameSize = RNNoiseProcessor.frameSize
        let scaleFactor: Float = 32768.0
        let invScaleFactor: Float = 1.0 / 32768.0
        var result = [Float](repeating: 0, count: count)
        var offset = 0

        while offset < count {
            let remaining = count - offset
            let currentSize = min(frameSize, remaining)

            var inputFrame = [Float](repeating: 0, count: frameSize)
            for i in 0..<currentSize {
                inputFrame[i] = samples[offset + i] * scaleFactor
            }

            var outputFrame = [Float](repeating: 0, count: frameSize)
            processor.processFrame(output: &outputFrame, input: &inputFrame)

            for i in 0..<currentSize {
                let denoised = outputFrame[i] * invScaleFactor
                if clampedStrength >= 1.0 {
                    result[offset + i] = denoised
                } else {
                    result[offset + i] = samples[offset + i] * (1.0 - clampedStrength) + denoised * clampedStrength
                }
            }

            offset += frameSize
        }

        return result
    }

    // MARK: - 格式转换辅助

    /// 将单声道 Float 数组转换为双声道非交错 PCMBuffer（复制到左右声道）
    private func monoToStereoBuffer(_ monoSamples: [Float], count: Int) throws -> AVAudioPCMBuffer {
        let stereoFormat = Self.outputFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: AVAudioFrameCount(count)) else {
            throw StreamingDenoiserError.conversionFailed(L10n.string(.serviceErrorStereoBufferCreationFailed))
        }
        buffer.frameLength = AVAudioFrameCount(count)

        if let channelData = buffer.floatChannelData {
            monoSamples.withUnsafeBufferPointer { src in
                channelData[0].update(from: src.baseAddress!, count: count)
                if Self.channels > 1 {
                    channelData[1].update(from: src.baseAddress!, count: count)
                }
            }
        }

        return buffer
    }
}

// MARK: - 错误类型

enum StreamingDenoiserError: LocalizedError {
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .conversionFailed(let msg):
            return L10n.string(.serviceErrorConversionFailed, msg)
        }
    }
}
