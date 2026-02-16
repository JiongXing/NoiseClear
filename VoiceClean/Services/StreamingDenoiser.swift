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
/// 与 `FFmpegDenoiser` 不同，本类将 FFmpeg 输出重定向到 stdout pipe，
/// 应用从 pipe 中持续读取 raw PCM 数据块，供 AVAudioEngine 实时播放。
///
/// 处理流程: 输入文件 → FFmpeg Process → arnndn 滤镜 → stdout pipe (raw PCM f32le)
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

    // MARK: - 属性

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

    /// 是否已启动
    private(set) var isRunning: Bool = false

    /// 线程安全锁，防止 stop() 被多线程同时执行
    private let stopLock = NSLock()

    // MARK: - 初始化

    init() throws {
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
    }

    // MARK: - 启动流式降噪

    /// 启动 FFmpeg 进程进行流式降噪
    /// - Parameters:
    ///   - inputURL: 输入媒体文件
    ///   - strength: 降噪强度 (0.0 ~ 1.0)
    ///   - startTime: 起始播放时间（秒），用于 seek
    ///   - isVideo: 是否为视频文件（视频模式仅提取音频轨道）
    func start(
        inputURL: URL,
        strength: Float,
        startTime: TimeInterval = 0,
        maxDuration: TimeInterval? = nil,
        isVideo: Bool = false
    ) throws {
        // 先停止已有进程
        stop()

        let clampedStrength = max(0.0, min(1.0, strength))
        let mixValue = String(format: "%.2f", clampedStrength)
        let filterChain = "arnndn=m=\(modelURL.path):mix=\(mixValue)"

        var arguments: [String] = ["-y"]

        // seek 参数（放在 -i 之前为 input seeking，更快）
        if startTime > 0.5 {
            arguments += ["-ss", String(format: "%.3f", startTime)]
        }

        arguments += ["-i", inputURL.path]

        if let maxDuration, maxDuration > 0.01 {
            arguments += ["-t", String(format: "%.3f", maxDuration)]
        }

        // 视频文件丢弃视频流
        if isVideo {
            arguments += ["-vn"]
        }

        arguments += [
            "-af", filterChain,                     // arnndn 降噪滤镜
            "-ar", "\(Int(Self.sampleRate))",        // 48kHz
            "-ac", "\(Self.channels)",               // 双声道
            "-f", "f32le",                           // raw Float32 little-endian PCM
            "-loglevel", "error",
            "pipe:1"                                 // 输出到 stdout
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

    // MARK: - 启动原始播放（不降噪）

    /// 启动 FFmpeg 进程进行原始音频输出（不应用降噪滤镜）
    func startOriginal(
        inputURL: URL,
        startTime: TimeInterval = 0,
        maxDuration: TimeInterval? = nil,
        isVideo: Bool = false
    ) throws {
        stop()

        var arguments: [String] = ["-y"]

        if startTime > 0.5 {
            arguments += ["-ss", String(format: "%.3f", startTime)]
        }

        arguments += ["-i", inputURL.path]

        if let maxDuration, maxDuration > 0.01 {
            arguments += ["-t", String(format: "%.3f", maxDuration)]
        }

        if isVideo {
            arguments += ["-vn"]
        }

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

    // MARK: - 读取 PCM 数据

    /// 从 stdout pipe 读取下一个 PCM buffer
    ///
    /// - Returns: 填充好的 AVAudioPCMBuffer，EOF 或出错时返回 nil
    func readNextBuffer() -> AVAudioPCMBuffer? {
        guard let pipe = stdoutPipe else { return nil }

        let fileHandle = pipe.fileHandleForReading
        let bytesToRead = Self.readSize
        let data = fileHandle.readData(ofLength: bytesToRead)

        guard !data.isEmpty else {
            // EOF — FFmpeg 处理完毕
            return nil
        }

        let format = Self.outputFormat
        let framesRead = AVAudioFrameCount(data.count / Self.bytesPerFrame)
        guard framesRead > 0 else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesRead) else {
            return nil
        }
        buffer.frameLength = framesRead

        // FFmpeg 输出交错数据 (L0 R0 L1 R1 ...)，需反交错为分离通道
        // 非交错格式下 floatChannelData[0] = 左声道, [1] = 右声道
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

    // MARK: - 停止

    /// 停止 FFmpeg 进程并清理资源（线程安全）
    func stop() {
        stopLock.lock()

        let proc = self.process
        let outPipe = self.stdoutPipe
        let errPipe = self.stderrPipe

        self.process = nil
        self.stdoutPipe = nil
        self.stderrPipe = nil
        self.isRunning = false

        stopLock.unlock()

        guard let proc else { return }

        // 先关闭管道读端，让 FFmpeg 写操作收到 SIGPIPE，
        // 避免 waitUntilExit 因管道缓冲区满而死锁
        try? outPipe?.fileHandleForReading.close()
        try? errPipe?.fileHandleForReading.close()

        if proc.isRunning {
            proc.terminate()
        }
        proc.waitUntilExit()
    }

    deinit {
        stop()
    }
}

// MARK: - 错误类型

enum StreamingDenoiserError: LocalizedError {
    case ffmpegNotFound
    case modelNotFound
    case processLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "找不到 FFmpeg 可执行文件 — 请确保 ffmpeg 已添加到项目 Resources 中"
        case .modelNotFound:
            return "找不到 RNNoise 模型文件 (std.rnnn) — 请确保模型文件已添加到项目 Resources 中"
        case .processLaunchFailed(let msg):
            return "FFmpeg 流式进程启动失败: \(msg)"
        }
    }
}
