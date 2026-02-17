//
//  StreamingDenoiser.swift
//  VoiceClean
//
//  Created by jxing on 2026/2/15.
//

import AVFoundation
import Foundation

// MARK: - 流式降噪引擎

/// 基于 FFmpeg arnndn 滤镜的流式降噪引擎
///
/// - macOS: 通过 FFmpeg Process 将 PCM 输出到 stdout pipe，实时读取播放
/// - iOS: 通过 AVFoundation 解码 + RNNoise 降噪，输出到临时 WAV 文件，再用 AVAudioFile 读取
final class StreamingDenoiser {

    // MARK: - 常量

    /// 输出采样率（播放质量优先）
    static let sampleRate: Double = 48000.0

    /// 输出声道数（双声道立体声）
    static let channels: UInt32 = 2

    /// 每次读取的帧数（4096 帧 ≈ 85ms @48kHz）
    static let bufferFrameCount: AVAudioFrameCount = 4096

    /// 每帧字节数：channels × sizeof(Float32)
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

    // MARK: - 共享属性

    /// 是否已启动
    private(set) var isRunning: Bool = false

    /// 线程安全锁
    private let stopLock = NSLock()

    // MARK: - macOS 属性（Process + Pipe）

    #if os(macOS)
    /// 当前运行的 FFmpeg 进程
    private var process: Process?

    /// stdout pipe（PCM 数据输出）
    private var stdoutPipe: Pipe?

    /// stderr pipe（错误信息）
    private var stderrPipe: Pipe?

    /// FFmpeg 二进制路径
    private let ffmpegURL: URL

    /// RNNoise 模型路径
    private let modelURL: URL
    #endif

    // MARK: - iOS 属性（临时文件 + AVAudioFile）

    #if os(iOS)
    /// 降噪后的临时 WAV 文件 URL
    private var tempFileURL: URL?

    /// 用于读取临时 WAV 的 AVAudioFile
    private var audioFileReader: AVAudioFile?

    /// RNNoise 处理要求的采样率（48kHz 单声道）
    private static let rnnoiseMonoFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48000.0,
        channels: 1,
        interleaved: false
    )!
    #endif

    // MARK: - 初始化

    init() throws {
        #if os(macOS)
        guard let ffmpegPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) else {
            throw StreamingDenoiserError.ffmpegNotFound
        }
        self.ffmpegURL = URL(fileURLWithPath: ffmpegPath)

        guard let modelPath = Bundle.main.path(forResource: "std", ofType: "rnnn") else {
            throw StreamingDenoiserError.modelNotFound
        }
        self.modelURL = URL(fileURLWithPath: modelPath)

        // 确保 ffmpeg 有执行权限
        let fm = FileManager.default
        if !fm.isExecutableFile(atPath: ffmpegPath) {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffmpegPath)
        }
        #else
        // iOS: RNNoise 模型由 RNNoiseProcessor 内部加载，此处无需额外检查
        #endif
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

        #if os(macOS)
        try startWithProcess(
            inputURL: inputURL,
            strength: strength,
            startTime: startTime,
            maxDuration: maxDuration,
            isVideo: isVideo
        )
        #else
        try startWithTempFile(
            inputURL: inputURL,
            strength: strength,
            startTime: startTime,
            maxDuration: maxDuration,
            isVideo: isVideo
        )
        #endif
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

        #if os(macOS)
        try startOriginalWithProcess(
            inputURL: inputURL,
            startTime: startTime,
            maxDuration: maxDuration,
            isVideo: isVideo
        )
        #else
        try startOriginalWithTempFile(
            inputURL: inputURL,
            startTime: startTime,
            maxDuration: maxDuration,
            isVideo: isVideo
        )
        #endif
    }

    // MARK: - 读取 PCM 数据

    /// 读取下一个 PCM buffer
    ///
    /// - Returns: 填充好的 AVAudioPCMBuffer，EOF 或出错时返回 nil
    func readNextBuffer() -> AVAudioPCMBuffer? {
        #if os(macOS)
        return readFromPipe()
        #else
        return readFromAudioFile()
        #endif
    }

    // MARK: - 停止

    /// 停止并清理资源（线程安全）
    func stop() {
        stopLock.lock()

        #if os(macOS)
        let proc = self.process
        let outPipe = self.stdoutPipe
        let errPipe = self.stderrPipe

        self.process = nil
        self.stdoutPipe = nil
        self.stderrPipe = nil
        #else
        let tempURL = self.tempFileURL
        self.audioFileReader = nil
        self.tempFileURL = nil
        #endif

        self.isRunning = false
        stopLock.unlock()

        #if os(macOS)
        guard let proc else { return }
        try? outPipe?.fileHandleForReading.close()
        try? errPipe?.fileHandleForReading.close()
        if proc.isRunning { proc.terminate() }
        proc.waitUntilExit()
        #else
        // 清理临时文件
        if let tempURL {
            try? FileManager.default.removeItem(at: tempURL)
        }
        #endif
    }

    deinit {
        stop()
    }

    // MARK: - macOS: Process + Pipe 实现

    #if os(macOS)
    private func startWithProcess(
        inputURL: URL,
        strength: Float,
        startTime: TimeInterval,
        maxDuration: TimeInterval?,
        isVideo: Bool
    ) throws {
        let clampedStrength = max(0.0, min(1.0, strength))
        let mixValue = String(format: "%.2f", clampedStrength)
        let filterChain = "arnndn=m=\(modelURL.path):mix=\(mixValue)"

        var arguments: [String] = ["-y"]
        if startTime > 0.5 {
            arguments += ["-ss", String(format: "%.3f", startTime)]
        }
        arguments += ["-i", inputURL.path]
        if let maxDuration, maxDuration > 0.01 {
            arguments += ["-t", String(format: "%.3f", maxDuration)]
        }
        if isVideo { arguments += ["-vn"] }
        arguments += [
            "-af", filterChain,
            "-ar", "\(Int(Self.sampleRate))",
            "-ac", "\(Self.channels)",
            "-f", "f32le",
            "-loglevel", "error",
            "pipe:1"
        ]

        let proc = Process()
        proc.executableURL = ffmpegURL
        proc.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["AV_LOG_FORCE_NOCOLOR"] = "1"
        proc.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()

        self.process = proc
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe
        self.isRunning = true
    }

    private func startOriginalWithProcess(
        inputURL: URL,
        startTime: TimeInterval,
        maxDuration: TimeInterval?,
        isVideo: Bool
    ) throws {
        var arguments: [String] = ["-y"]
        if startTime > 0.5 {
            arguments += ["-ss", String(format: "%.3f", startTime)]
        }
        arguments += ["-i", inputURL.path]
        if let maxDuration, maxDuration > 0.01 {
            arguments += ["-t", String(format: "%.3f", maxDuration)]
        }
        if isVideo { arguments += ["-vn"] }
        arguments += [
            "-ar", "\(Int(Self.sampleRate))",
            "-ac", "\(Self.channels)",
            "-f", "f32le",
            "-loglevel", "error",
            "pipe:1"
        ]

        let proc = Process()
        proc.executableURL = ffmpegURL
        proc.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["AV_LOG_FORCE_NOCOLOR"] = "1"
        proc.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()

        self.process = proc
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe
        self.isRunning = true
    }

    private func readFromPipe() -> AVAudioPCMBuffer? {
        guard let pipe = stdoutPipe else { return nil }

        let fileHandle = pipe.fileHandleForReading
        let data = fileHandle.readData(ofLength: Self.readSize)
        guard !data.isEmpty else { return nil }

        let format = Self.outputFormat
        let framesRead = AVAudioFrameCount(data.count / Self.bytesPerFrame)
        guard framesRead > 0 else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesRead) else {
            return nil
        }
        buffer.frameLength = framesRead

        let channelCount = Int(Self.channels)
        data.withUnsafeBytes { rawPtr in
            guard let src = rawPtr.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            guard let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(framesRead)
            for frame in 0..<frameCount {
                for ch in 0..<channelCount {
                    channelData[ch][frame] = src[frame * channelCount + ch]
                }
            }
        }

        return buffer
    }
    #endif

    // MARK: - iOS: 临时文件 + AVAudioFile 实现

    #if os(iOS)
    private func startWithTempFile(
        inputURL: URL,
        strength: Float,
        startTime: TimeInterval,
        maxDuration: TimeInterval?,
        isVideo: Bool
    ) throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming_denoise_\(UUID().uuidString).wav")
        self.tempFileURL = tempURL

        // 使用 AVFoundation 解码 + RNNoise 降噪
        try convertAndDenoiseChunk(
            inputURL: inputURL,
            outputURL: tempURL,
            startTime: startTime,
            maxDuration: maxDuration,
            isVideo: isVideo,
            strength: strength
        )

        self.audioFileReader = try AVAudioFile(forReading: tempURL)
        self.isRunning = true
    }

    private func startOriginalWithTempFile(
        inputURL: URL,
        startTime: TimeInterval,
        maxDuration: TimeInterval?,
        isVideo: Bool
    ) throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming_original_\(UUID().uuidString).wav")
        self.tempFileURL = tempURL

        // 仅格式转换，不降噪
        try convertChunkWithAVFoundation(
            inputURL: inputURL,
            outputURL: tempURL,
            startTime: startTime,
            maxDuration: maxDuration,
            isVideo: isVideo
        )

        self.audioFileReader = try AVAudioFile(forReading: tempURL)
        self.isRunning = true
    }

    // MARK: - iOS: AVFoundation + RNNoise 降噪

    /// 使用 AVFoundation 解码 + RNNoise 进行实时降噪
    ///
    /// 流程: 输入文件 → AVFoundation 解码 → 重采样至 48kHz 单声道 → RNNoise 降噪 → 还原为立体声 → 写入 WAV
    private func convertAndDenoiseChunk(
        inputURL: URL,
        outputURL: URL,
        startTime: TimeInterval,
        maxDuration: TimeInterval?,
        isVideo: Bool,
        strength: Float
    ) throws {
        // 1. 先用 AVFoundation 解码为 48kHz 单声道（RNNoise 要求）
        let monoTempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rnnoise_mono_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: monoTempURL) }

        if isVideo {
            try convertVideoAudioToMono(
                inputURL: inputURL,
                outputURL: monoTempURL,
                startTime: startTime,
                maxDuration: maxDuration
            )
        } else {
            try convertAudioToMono(
                inputURL: inputURL,
                outputURL: monoTempURL,
                startTime: startTime,
                maxDuration: maxDuration
            )
        }

        // 2. 读取单声道 PCM 数据，应用 RNNoise 降噪
        let monoFile = try AVAudioFile(forReading: monoTempURL)
        let monoFrameCount = AVAudioFrameCount(monoFile.length)
        guard monoFrameCount > 0 else {
            throw StreamingDenoiserError.conversionFailed("解码后数据为空")
        }

        let monoFormat = monoFile.processingFormat
        guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: monoFrameCount) else {
            throw StreamingDenoiserError.conversionFailed("无法创建单声道缓冲区")
        }
        try monoFile.read(into: monoBuffer, frameCount: monoFrameCount)

        guard let monoData = monoBuffer.floatChannelData?[0] else {
            throw StreamingDenoiserError.conversionFailed("无法读取单声道数据")
        }

        let sampleCount = Int(monoBuffer.frameLength)
        let processor = try RNNoiseProcessor()
        defer { processor.close() }

        let frameSize = RNNoiseProcessor.frameSize
        let clampedStrength = max(0.0, min(1.0, strength))
        let scaleFactor: Float = 32768.0
        let invScaleFactor: Float = 1.0 / 32768.0

        // 3. 逐帧降噪（RNNoise 期望 int16 范围的 float: -32768~32768）
        var denoisedMono = [Float](repeating: 0, count: sampleCount)
        var offset = 0
        while offset < sampleCount {
            let remaining = sampleCount - offset
            let currentSize = min(frameSize, remaining)

            var inputFrame = [Float](repeating: 0, count: frameSize)
            for i in 0..<currentSize {
                inputFrame[i] = monoData[offset + i] * scaleFactor
            }

            var outputFrame = [Float](repeating: 0, count: frameSize)
            processor.processFrame(output: &outputFrame, input: &inputFrame)

            // 混合原始和降噪信号（先将 RNNoise 输出缩放回 float 范围）
            for i in 0..<currentSize {
                let denoised = outputFrame[i] * invScaleFactor
                if clampedStrength >= 1.0 {
                    denoisedMono[offset + i] = denoised
                } else {
                    denoisedMono[offset + i] = monoData[offset + i] * (1.0 - clampedStrength) + denoised * clampedStrength
                }
            }

            offset += frameSize
        }

        // 4. 单声道 → 双声道（复制到左右声道）
        let stereoFormat = Self.outputFormat  // 非交错 Float32 48kHz 双声道
        guard let stereoBuffer = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: AVAudioFrameCount(sampleCount)) else {
            throw StreamingDenoiserError.conversionFailed("无法创建立体声缓冲区")
        }
        stereoBuffer.frameLength = AVAudioFrameCount(sampleCount)

        if let stereoChannels = stereoBuffer.floatChannelData {
            denoisedMono.withUnsafeBufferPointer { src in
                // 复制到左声道
                stereoChannels[0].update(from: src.baseAddress!, count: sampleCount)
                // 复制到右声道
                if Self.channels > 1 {
                    stereoChannels[1].update(from: src.baseAddress!, count: sampleCount)
                }
            }
        }

        // 5. 写入输出 WAV
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: Self.wavFileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try outputFile.write(from: stereoBuffer)
    }

    /// 将纯音频文件转换为 48kHz 单声道
    private func convertAudioToMono(
        inputURL: URL,
        outputURL: URL,
        startTime: TimeInterval,
        maxDuration: TimeInterval?
    ) throws {
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
            throw StreamingDenoiserError.conversionFailed("无可读取的音频帧")
        }

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: maxFrames) else {
            throw StreamingDenoiserError.conversionFailed("无法创建输入缓冲区")
        }
        try inputFile.read(into: inputBuffer, frameCount: maxFrames)

        let monoFormat = Self.rnnoiseMonoFormat
        guard let converter = AVAudioConverter(from: inputFormat, to: monoFormat) else {
            throw StreamingDenoiserError.conversionFailed("无法创建格式转换器")
        }

        let ratio = RNNoiseProcessor.sampleRate / inputSR
        let outCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 256
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: outCapacity) else {
            throw StreamingDenoiserError.conversionFailed("无法创建输出缓冲区")
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

        let monoSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: RNNoiseProcessor.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: monoSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try outputFile.write(from: outputBuffer)
    }

    /// 从视频文件提取音频并转换为 48kHz 单声道
    private func convertVideoAudioToMono(
        inputURL: URL,
        outputURL: URL,
        startTime: TimeInterval,
        maxDuration: TimeInterval?
    ) throws {
        let asset = AVURLAsset(url: inputURL)
        guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
            throw StreamingDenoiserError.conversionFailed("视频文件中未找到音频轨道")
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
                reader.error?.localizedDescription ?? "AVAssetReader 启动失败"
            )
        }

        let monoFormat = Self.rnnoiseMonoFormat
        let monoSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: RNNoiseProcessor.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: monoSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

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

            let frameCount = AVAudioFrameCount(numSamples)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCount) else { continue }
            buffer.frameLength = frameCount

            let bytesToCopy = min(totalLength, Int(frameCount) * MemoryLayout<Float>.size)
            memcpy(buffer.floatChannelData![0], data, bytesToCopy)

            try outputFile.write(from: buffer)
        }
    }

    // MARK: - iOS: AVFoundation 格式转换（无降噪）

    /// 使用 AVFoundation 将音频/视频的音频轨道转换为目标格式 WAV 文件（无降噪）
    private func convertChunkWithAVFoundation(
        inputURL: URL,
        outputURL: URL,
        startTime: TimeInterval,
        maxDuration: TimeInterval?,
        isVideo: Bool
    ) throws {
        if isVideo {
            try convertVideoAudioChunk(
                inputURL: inputURL,
                outputURL: outputURL,
                startTime: startTime,
                maxDuration: maxDuration
            )
        } else {
            try convertAudioChunk(
                inputURL: inputURL,
                outputURL: outputURL,
                startTime: startTime,
                maxDuration: maxDuration
            )
        }
    }

    /// WAV 文件设置（磁盘上的格式：交错 Float32 PCM）
    private static var wavFileSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    /// 使用 AVAudioFile 转换纯音频文件的指定区间
    private func convertAudioChunk(
        inputURL: URL,
        outputURL: URL,
        startTime: TimeInterval,
        maxDuration: TimeInterval?
    ) throws {
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
            throw StreamingDenoiserError.conversionFailed("无可读取的音频帧")
        }

        // 读取输入数据
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: maxFrames) else {
            throw StreamingDenoiserError.conversionFailed("无法创建输入缓冲区")
        }
        try inputFile.read(into: inputBuffer, frameCount: maxFrames)
        guard inputBuffer.frameLength > 0 else {
            throw StreamingDenoiserError.conversionFailed("读取到空数据")
        }

        // 目标格式：非交错 Float32（与 Self.outputFormat 一致，匹配 AVAudioFile 默认处理格式）
        let writeFormat = Self.outputFormat

        // 格式转换
        guard let converter = AVAudioConverter(from: inputFormat, to: writeFormat) else {
            throw StreamingDenoiserError.conversionFailed("无法创建格式转换器")
        }
        let ratio = Self.sampleRate / inputSR
        let outCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 256
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: writeFormat, frameCapacity: outCapacity) else {
            throw StreamingDenoiserError.conversionFailed("无法创建输出缓冲区")
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
        guard outputBuffer.frameLength > 0 else {
            throw StreamingDenoiserError.conversionFailed("格式转换输出为空")
        }

        // 写入临时 WAV 文件
        // settings 指定磁盘格式（交错 WAV），commonFormat+interleaved 指定处理格式（非交错，匹配 buffer）
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: Self.wavFileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try outputFile.write(from: outputBuffer)
    }

    /// 使用 AVAssetReader 从视频文件提取并转换音频
    private func convertVideoAudioChunk(
        inputURL: URL,
        outputURL: URL,
        startTime: TimeInterval,
        maxDuration: TimeInterval?
    ) throws {
        let asset = AVURLAsset(url: inputURL)
        guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
            throw StreamingDenoiserError.conversionFailed("视频文件中未找到音频轨道")
        }

        let reader = try AVAssetReader(asset: asset)
        let start = CMTime(seconds: startTime, preferredTimescale: 48000)
        let dur = maxDuration.map { CMTime(seconds: $0, preferredTimescale: 48000) } ?? CMTime.positiveInfinity
        reader.timeRange = CMTimeRange(start: start, duration: dur)

        // AVAssetReader 输出交错格式 PCM
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
                reader.error?.localizedDescription ?? "AVAssetReader 启动失败"
            )
        }

        // 交错格式（匹配 AVAssetReader 输出）
        guard let interleavedFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: Self.channels,
            interleaved: true
        ) else {
            throw StreamingDenoiserError.conversionFailed("无法创建交错格式")
        }

        // 写入文件：磁盘格式交错，处理格式也是交错（匹配 AVAssetReader 输出的 buffer）
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: Self.wavFileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: true
        )

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

            let frameCount = AVAudioFrameCount(numSamples)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: interleavedFormat, frameCapacity: frameCount) else { continue }
            buffer.frameLength = frameCount

            let bytesToCopy = min(totalLength, Int(frameCount) * Int(Self.channels) * MemoryLayout<Float>.size)
            memcpy(buffer.floatChannelData![0], data, bytesToCopy)

            try outputFile.write(from: buffer)
        }
    }

    // MARK: - iOS: 读取 AVAudioFile

    private func readFromAudioFile() -> AVAudioPCMBuffer? {
        guard let audioFile = audioFileReader else { return nil }

        let format = Self.outputFormat
        let framesToRead = Self.bufferFrameCount
        let remaining = AVAudioFrameCount(audioFile.length - audioFile.framePosition)
        guard remaining > 0 else { return nil }

        let actualFrames = min(framesToRead, remaining)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: actualFrames) else {
            return nil
        }

        do {
            try audioFile.read(into: buffer, frameCount: actualFrames)
        } catch {
            return nil
        }

        return buffer.frameLength > 0 ? buffer : nil
    }
    #endif
}

// MARK: - 错误类型

enum StreamingDenoiserError: LocalizedError {
    #if os(macOS)
    case ffmpegNotFound
    case processLaunchFailed(String)
    #endif
    case modelNotFound
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        #if os(macOS)
        case .ffmpegNotFound:
            return "找不到 FFmpeg 可执行文件 — 请确保 ffmpeg 已添加到项目 Resources 中"
        case .processLaunchFailed(let msg):
            return "FFmpeg 流式进程启动失败: \(msg)"
        #endif
        case .modelNotFound:
            return "找不到 RNNoise 模型文件 (std.rnnn) — 请确保模型文件已添加到项目 Resources 中"
        case .conversionFailed(let msg):
            return "音频转换失败: \(msg)"
        }
    }
}
