//
//  FFmpegDenoiser.swift
//  VoiceClean
//
//  Created by jxing on 2026/2/14.
//

import AVFoundation
import Foundation

// MARK: - FFmpeg 降噪引擎

/// 基于 FFmpeg arnndn 滤镜 (RNNoise) 的音频降噪引擎
///
/// arnndn (Audio Recurrent Neural Network Denoiser) 使用 RNNoise 神经网络
/// 专门针对人声进行降噪，能有效去除背景噪声同时保留语音质量。
///
/// - macOS: 通过 Process 启动 FFmpeg 二进制（性能好，支持 pipe 流式输出）
/// - iOS: 通过 AVFoundation 解码 + RNNoise 降噪（原生方案，不依赖 FFmpeg）
final class FFmpegDenoiser: Sendable {

    // MARK: - 常量

    /// 输出音频采样率 (Hz)
    static let outputSampleRate: Double = 16000.0

    // MARK: - 属性

    /// 降噪强度 (0.0 ~ 1.0)，映射到 arnndn 的 mix 参数
    private let denoiseStrength: Float

    #if os(macOS)
    /// FFmpeg 二进制文件路径（仅 macOS）
    private let ffmpegURL: URL

    /// RNNoise 模型文件路径（仅 macOS）
    private let modelURL: URL
    #endif

    // MARK: - 初始化

    /// 初始化降噪引擎
    /// - Parameter strength: 降噪强度 (0.0 ~ 1.0)，默认 1.0（全强度）
    init(strength: Float = 1.0) throws {
        self.denoiseStrength = max(0.0, min(1.0, strength))

        #if os(macOS)
        // 定位 Bundle 内的 FFmpeg 二进制
        guard let ffmpegPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) else {
            throw FFmpegDenoiserError.ffmpegNotFound
        }
        self.ffmpegURL = URL(fileURLWithPath: ffmpegPath)

        // 定位 Bundle 内的 RNNoise 模型文件
        guard let modelPath = Bundle.main.path(forResource: "std", ofType: "rnnn") else {
            throw FFmpegDenoiserError.modelNotFound
        }
        self.modelURL = URL(fileURLWithPath: modelPath)

        // 确保 ffmpeg 有执行权限
        let fileManager = FileManager.default
        if !fileManager.isExecutableFile(atPath: ffmpegPath) {
            try? fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: ffmpegPath
            )
        }
        #else
        // iOS: 使用原生 AVFoundation + RNNoise，模型由 RNNoiseProcessor 内部加载
        #endif
    }

    // MARK: - 主处理方法

    /// 对音频或视频文件执行降噪处理
    /// - Parameters:
    ///   - inputURL: 输入文件 URL（音频或视频）
    ///   - outputURL: 输出文件 URL（音频→WAV，视频→原格式）
    ///   - duration: 媒体总时长（秒），用于计算进度
    ///   - isVideo: 是否为视频文件（视频模式下保留视频流，仅降噪音频轨道）
    ///   - onProgress: 进度回调 (0.0 ~ 1.0)
    func process(
        inputURL: URL,
        outputURL: URL,
        duration: TimeInterval,
        isVideo: Bool = false,
        onProgress: @escaping @Sendable (Double) -> Void
    ) throws {
        #if os(macOS)
        try processWithFFmpegCLI(
            inputURL: inputURL,
            outputURL: outputURL,
            duration: duration,
            isVideo: isVideo,
            onProgress: onProgress
        )
        #else
        try processWithFFmpegLib(
            inputURL: inputURL,
            outputURL: outputURL,
            duration: duration,
            isVideo: isVideo,
            onProgress: onProgress
        )
        #endif
    }

    // MARK: - iOS: 使用 AVFoundation + RNNoise

    #if os(iOS)
    private func processWithFFmpegLib(
        inputURL: URL,
        outputURL: URL,
        duration: TimeInterval,
        isVideo: Bool,
        onProgress: @escaping @Sendable (Double) -> Void
    ) throws {
        if isVideo {
            try denoiseVideoNative(
                inputURL: inputURL,
                outputURL: outputURL,
                duration: duration,
                onProgress: onProgress
            )
        } else {
            try denoiseAudioNative(
                inputURL: inputURL,
                outputURL: outputURL,
                duration: duration,
                onProgress: onProgress
            )
        }

        // 验证输出文件存在
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw FFmpegDenoiserError.outputFileMissing
        }
    }

    /// 使用 AVFoundation + RNNoise 对纯音频文件降噪
    private func denoiseAudioNative(
        inputURL: URL,
        outputURL: URL,
        duration: TimeInterval,
        onProgress: @escaping @Sendable (Double) -> Void
    ) throws {
        // 1. 读取源文件并转换为 48kHz 单声道（RNNoise 要求）
        let sourceFile = try AVAudioFile(forReading: inputURL)
        let sourceFormat = sourceFile.processingFormat
        let sourceFrameCount = AVAudioFrameCount(sourceFile.length)

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceFrameCount) else {
            throw FFmpegDenoiserError.outputFileMissing
        }
        try sourceFile.read(into: sourceBuffer)
        onProgress(0.1)

        // 目标：48kHz 单声道
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: RNNoiseProcessor.sampleRate,
            channels: 1,
            interleaved: false
        )!

        guard let converter = AVAudioConverter(from: sourceFormat, to: monoFormat) else {
            throw FFmpegDenoiserError.outputFileMissing
        }

        let ratio = RNNoiseProcessor.sampleRate / sourceFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(sourceFrameCount) * ratio) + 256
        guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: outCapacity) else {
            throw FFmpegDenoiserError.outputFileMissing
        }

        var isDone = false
        var convError: NSError?
        converter.convert(to: monoBuffer, error: &convError) { _, outStatus in
            if isDone {
                outStatus.pointee = .noDataNow
                return nil
            }
            isDone = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        if let convError { throw FFmpegDenoiserError.processingFailed(convError.localizedDescription) }
        onProgress(0.3)

        // 2. RNNoise 逐帧降噪
        guard let monoData = monoBuffer.floatChannelData?[0] else {
            throw FFmpegDenoiserError.outputFileMissing
        }
        let sampleCount = Int(monoBuffer.frameLength)
        let processor = try RNNoiseProcessor()
        defer { processor.close() }

        let frameSize = RNNoiseProcessor.frameSize
        let scaleFactor: Float = 32768.0
        let invScaleFactor: Float = 1.0 / 32768.0
        var denoisedSamples = [Float](repeating: 0, count: sampleCount)
        let strength = denoiseStrength
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

            for i in 0..<currentSize {
                let denoised = outputFrame[i] * invScaleFactor
                if strength >= 1.0 {
                    denoisedSamples[offset + i] = denoised
                } else {
                    denoisedSamples[offset + i] = monoData[offset + i] * (1.0 - strength) + denoised * strength
                }
            }

            offset += frameSize

            // 进度：0.3 ~ 0.9 之间
            let denoiseProgress = Double(offset) / Double(sampleCount)
            onProgress(0.3 + denoiseProgress * 0.6)
        }

        // 3. 降采样到输出采样率（16kHz）并写入
        let denoisedFormat = monoFormat
        guard let denoisedBuffer = AVAudioPCMBuffer(pcmFormat: denoisedFormat, frameCapacity: AVAudioFrameCount(sampleCount)) else {
            throw FFmpegDenoiserError.outputFileMissing
        }
        denoisedBuffer.frameLength = AVAudioFrameCount(sampleCount)
        denoisedSamples.withUnsafeBufferPointer { src in
            denoisedBuffer.floatChannelData![0].update(from: src.baseAddress!, count: sampleCount)
        }

        // 输出格式：16kHz 单声道
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.outputSampleRate,
            channels: 1,
            interleaved: false
        )!

        guard let outConverter = AVAudioConverter(from: denoisedFormat, to: outputFormat) else {
            throw FFmpegDenoiserError.outputFileMissing
        }

        let outRatio = Self.outputSampleRate / RNNoiseProcessor.sampleRate
        let finalCapacity = AVAudioFrameCount(Double(sampleCount) * outRatio) + 256
        guard let finalBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: finalCapacity) else {
            throw FFmpegDenoiserError.outputFileMissing
        }

        var outDone = false
        var outConvError: NSError?
        outConverter.convert(to: finalBuffer, error: &outConvError) { _, outStatus in
            if outDone {
                outStatus.pointee = .noDataNow
                return nil
            }
            outDone = true
            outStatus.pointee = .haveData
            return denoisedBuffer
        }
        if let outConvError { throw FFmpegDenoiserError.processingFailed(outConvError.localizedDescription) }

        let outputFile = try AVAudioFile(forWriting: outputURL, settings: outputFormat.settings)
        try outputFile.write(from: finalBuffer)

        onProgress(1.0)
    }

    /// 使用 AVFoundation + RNNoise 对视频文件的音频轨道降噪
    ///
    /// 注意：iOS 原生无法像 FFmpeg 那样只替换音频轨道后重新封装视频。
    /// 此方法仅提取并降噪音频轨道，输出为 WAV 文件。
    /// 实际效果等价于提取音频 + 降噪。
    private func denoiseVideoNative(
        inputURL: URL,
        outputURL: URL,
        duration: TimeInterval,
        onProgress: @escaping @Sendable (Double) -> Void
    ) throws {
        let asset = AVURLAsset(url: inputURL)
        guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
            throw FFmpegDenoiserError.processingFailed("视频文件中未找到音频轨道")
        }

        let reader = try AVAssetReader(asset: asset)

        // 输出 48kHz 单声道给 RNNoise
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
            throw FFmpegDenoiserError.processingFailed(
                reader.error?.localizedDescription ?? "AVAssetReader 启动失败"
            )
        }
        onProgress(0.1)

        // 收集所有样本
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: RNNoiseProcessor.sampleRate,
            channels: 1,
            interleaved: false
        )!

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
        onProgress(0.3)

        // RNNoise 降噪
        let processor = try RNNoiseProcessor()
        defer { processor.close() }
        let denoisedSamples = processor.processAll(allSamples, strength: denoiseStrength)
        onProgress(0.8)

        // 降采样并写入输出文件
        let sampleCount = denoisedSamples.count
        guard let denoisedBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(sampleCount)) else {
            throw FFmpegDenoiserError.outputFileMissing
        }
        denoisedBuffer.frameLength = AVAudioFrameCount(sampleCount)
        denoisedSamples.withUnsafeBufferPointer { src in
            denoisedBuffer.floatChannelData![0].update(from: src.baseAddress!, count: sampleCount)
        }

        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.outputSampleRate,
            channels: 1,
            interleaved: false
        )!

        guard let outConverter = AVAudioConverter(from: monoFormat, to: outputFormat) else {
            throw FFmpegDenoiserError.outputFileMissing
        }

        let outRatio = Self.outputSampleRate / RNNoiseProcessor.sampleRate
        let finalCapacity = AVAudioFrameCount(Double(sampleCount) * outRatio) + 256
        guard let finalBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: finalCapacity) else {
            throw FFmpegDenoiserError.outputFileMissing
        }

        var outDone = false
        var outConvError: NSError?
        outConverter.convert(to: finalBuffer, error: &outConvError) { _, outStatus in
            if outDone {
                outStatus.pointee = .noDataNow
                return nil
            }
            outDone = true
            outStatus.pointee = .haveData
            return denoisedBuffer
        }
        if let outConvError { throw FFmpegDenoiserError.processingFailed(outConvError.localizedDescription) }

        let outputFile = try AVAudioFile(forWriting: outputURL, settings: outputFormat.settings)
        try outputFile.write(from: finalBuffer)

        onProgress(1.0)
    }
    #endif

    // MARK: - macOS: 使用 FFmpeg Process

    #if os(macOS)
    private func processWithFFmpegCLI(
        inputURL: URL,
        outputURL: URL,
        duration: TimeInterval,
        isVideo: Bool,
        onProgress: @escaping @Sendable (Double) -> Void
    ) throws {
        // 根据文件类型构建不同的 FFmpeg 参数
        let arguments: [String]
        if isVideo {
            arguments = buildVideoArguments(
                inputPath: inputURL.path,
                outputPath: outputURL.path
            )
        } else {
            arguments = buildArguments(
                inputPath: inputURL.path,
                outputPath: outputURL.path
            )
        }

        // 创建 Process
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = arguments

        // 设置环境变量，避免 FFmpeg 尝试读取终端
        var environment = ProcessInfo.processInfo.environment
        environment["AV_LOG_FORCE_NOCOLOR"] = "1"
        process.environment = environment

        // 捕获 stdout（-progress pipe:1 输出到 stdout）
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe

        // 捕获 stderr（FFmpeg 日志输出）
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        // 总时长（微秒），用于计算进度
        let totalDurationUs = duration * 1_000_000

        // 异步读取 stdout 解析进度
        let progressHandler = stdoutPipe.fileHandleForReading
        progressHandler.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let output = String(data: data, encoding: .utf8)
            else { return }

            // 解析 -progress 输出的 key=value 行
            let lines = output.components(separatedBy: .newlines)
            for line in lines {
                if line.hasPrefix("out_time_us=") {
                    let valueStr = line.replacingOccurrences(of: "out_time_us=", with: "")
                    if let timeUs = Double(valueStr), totalDurationUs > 0 {
                        let progress = min(1.0, max(0.0, timeUs / totalDurationUs))
                        onProgress(progress)
                    }
                }
            }
        }

        // 启动 FFmpeg 进程
        do {
            try process.run()
        } catch {
            progressHandler.readabilityHandler = nil
            throw FFmpegDenoiserError.processLaunchFailed(error.localizedDescription)
        }

        // 等待进程完成
        process.waitUntilExit()

        // 清理读取回调
        progressHandler.readabilityHandler = nil

        // 检查退出状态
        let exitCode = process.terminationStatus
        if exitCode != 0 {
            // 读取 stderr 获取错误信息
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrOutput = String(data: stderrData, encoding: .utf8) ?? "未知错误"

            // 提取最后几行有用的错误信息
            let errorLines = stderrOutput
                .components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
                .suffix(5)
                .joined(separator: "\n")

            throw FFmpegDenoiserError.processFailed(exitCode: exitCode, message: errorLines)
        }

        // 验证输出文件存在
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw FFmpegDenoiserError.outputFileMissing
        }

        // 最终进度 100%
        onProgress(1.0)
    }

    // MARK: - macOS 私有方法

    /// 构建纯音频降噪的 FFmpeg 命令行参数
    private func buildArguments(inputPath: String, outputPath: String) -> [String] {
        let mixValue = String(format: "%.2f", denoiseStrength)
        let filterChain = "arnndn=m=\(modelURL.path):mix=\(mixValue)"

        return [
            "-y",                       // 覆盖输出文件
            "-i", inputPath,            // 输入文件
            "-af", filterChain,         // 音频滤镜链
            "-ar", "16000",             // 输出采样率 16kHz
            "-ac", "1",                 // 单声道
            "-c:a", "pcm_f32le",        // Float32 PCM 编码器（WAV 格式）
            "-f", "wav",                // 输出格式 WAV
            "-progress", "pipe:1",      // 进度输出到 stdout
            "-loglevel", "error",       // 只输出错误日志到 stderr
            outputPath                  // 输出文件路径
        ]
    }

    /// 构建视频文件降噪的 FFmpeg 命令行参数
    private func buildVideoArguments(inputPath: String, outputPath: String) -> [String] {
        let mixValue = String(format: "%.2f", denoiseStrength)
        let filterChain = "arnndn=m=\(modelURL.path):mix=\(mixValue)"

        return [
            "-y",                       // 覆盖输出文件
            "-i", inputPath,            // 输入视频
            "-af", filterChain,         // 音频降噪滤镜
            "-c:v", "copy",             // 视频流直接复制，不重新编码（速度极快）
            "-c:a", "aac",              // 音频使用 AAC 编码
            "-b:a", "192k",             // 音频比特率 192kbps（高质量）
            "-movflags", "+faststart",  // MP4 快速启动（元数据前置）
            "-progress", "pipe:1",      // 进度输出到 stdout
            "-loglevel", "error",       // 只输出错误日志到 stderr
            outputPath                  // 输出文件路径
        ]
    }
    #endif
}

// MARK: - 错误类型

enum FFmpegDenoiserError: LocalizedError {
    #if os(macOS)
    case ffmpegNotFound
    case processLaunchFailed(String)
    case processFailed(exitCode: Int32, message: String)
    #endif
    case modelNotFound
    case outputFileMissing
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        #if os(macOS)
        case .ffmpegNotFound:
            return "找不到 FFmpeg 可执行文件 — 请确保 ffmpeg 已添加到项目 Resources 中"
        case .processLaunchFailed(let msg):
            return "FFmpeg 进程启动失败: \(msg)"
        case .processFailed(let code, let msg):
            return "FFmpeg 处理失败 (退出码 \(code)): \(msg)"
        #endif
        case .modelNotFound:
            return "找不到 RNNoise 模型文件 (std.rnnn) — 请确保模型文件已添加到项目 Resources 中"
        case .outputFileMissing:
            return "处理完成但输出文件不存在"
        case .processingFailed(let msg):
            return "音频处理失败: \(msg)"
        }
    }
}
