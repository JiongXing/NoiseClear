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
/// - iOS: 通过 FFmpegLibDenoiser 将音频处理到临时 WAV 文件，再用 AVAudioFile 读取
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
        guard Bundle.main.path(forResource: "std", ofType: "rnnn") != nil else {
            throw StreamingDenoiserError.modelNotFound
        }
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

        // 在后台线程中处理（FFmpegLibDenoiser 是同步阻塞的）
        // 但 start() 本身应阻塞直到文件准备好
        try FFmpegLibDenoiser.denoiseChunk(
            inputURL: inputURL,
            outputURL: tempURL,
            strength: strength,
            startTime: startTime,
            maxDuration: maxDuration,
            sampleRate: Int32(Self.sampleRate),
            channels: Int32(Self.channels),
            isVideo: isVideo
        )

        // 打开临时文件用于读取
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

        try FFmpegLibDenoiser.originalChunk(
            inputURL: inputURL,
            outputURL: tempURL,
            startTime: startTime,
            maxDuration: maxDuration,
            sampleRate: Int32(Self.sampleRate),
            channels: Int32(Self.channels),
            isVideo: isVideo
        )

        self.audioFileReader = try AVAudioFile(forReading: tempURL)
        self.isRunning = true
    }

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
        }
    }
}
