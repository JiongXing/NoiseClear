//
//  PlayerViewModel.swift
//  VoiceClean
//
//  Created by jxing on 2026/2/15.
//

import AVFoundation
import Foundation
import Observation

// MARK: - 降噪播放 ViewModel

/// 管理实时降噪播放的核心 ViewModel
///
/// 工作流程:
/// 1. 用户导入文件 → `loadFile(url:)` 获取时长等元数据
/// 2. 用户点击播放 → `play()` 启动 FFmpeg 管道 + AVAudioEngine
/// 3. 后台线程持续从 FFmpeg stdout pipe 读取 PCM 数据并调度到 AudioEngine
/// 4. 定时器更新当前播放时间
/// 5. 视频文件额外使用 AVPlayer 显示画面（静音）
@Observable
@MainActor
final class PlayerViewModel {

    // MARK: - 公开状态

    /// 当前已加载的文件 URL
    var currentFile: URL?

    /// 文件名
    var fileName: String = ""

    /// 是否为视频文件
    var isVideo: Bool = false

    /// 媒体总时长（秒）
    var duration: TimeInterval = 0

    /// 当前播放时间（秒）
    var currentTime: TimeInterval = 0

    /// 是否正在播放
    var isPlaying: Bool = false

    /// 是否正在加载/准备中
    var isLoading: Bool = false

    /// 降噪强度 (0.1 ~ 1.0)
    var denoiseStrength: Double = 0.8

    /// 是否启用降噪（关闭时播放原始音频做对比）
    var denoiseEnabled: Bool = true

    /// 音量 (0.0 ~ 1.0)
    var volume: Double = 1.0 {
        didSet {
            audioPlayer?.volume = Float(volume)
        }
    }

    /// 播放完毕
    var isFinished: Bool = false

    /// 错误信息
    var errorMessage: String?
    var showError: Bool = false

    // MARK: - 视频播放器（供 VideoPlayerView 使用）

    /// AVPlayer 实例，视频文件时非 nil
    var avPlayer: AVPlayer?

    // MARK: - 私有属性

    /// 流式降噪引擎
    private var denoiser: StreamingDenoiser?

    /// 音频播放引擎
    private var audioPlayer: AudioEnginePlayer?

    /// 后台读取队列
    private var readQueue: DispatchQueue?

    /// 播放时间更新定时器
    private var timeUpdateTimer: Timer?

    /// seek 起始时间偏移（用于计算真实播放时间）
    private var seekOffset: TimeInterval = 0

    /// 标记是否应继续读取数据
    private var shouldContinueReading: Bool = false

    /// 标记 FFmpeg 数据已全部读取完毕（但音频可能仍在播放）
    private var allDataRead: Bool = false

    /// 预填充 buffer 数量（播放前先缓冲避免卡顿）
    private let prefillBufferCount = 8

    // MARK: - 文件管理

    /// 加载媒体文件
    func loadFile(url: URL) async {
        // 清理之前的播放状态
        stop()

        let ext = url.pathExtension.lowercased()
        guard kAllSupportedExtensions.contains(ext) else {
            showErrorMessage("不支持的文件格式: .\(ext)")
            return
        }

        do {
            let fileDuration = try AudioFileService.getMediaDuration(url: url)

            self.currentFile = url
            self.fileName = url.lastPathComponent
            self.isVideo = kVideoExtensions.contains(ext)
            self.duration = fileDuration
            self.currentTime = 0
            self.isFinished = false

            // 视频文件：创建 AVPlayer
            if isVideo {
                let player = AVPlayer(url: url)
                player.isMuted = true  // 音频由 AVAudioEngine 播放
                self.avPlayer = player
            } else {
                self.avPlayer = nil
            }
        } catch {
            showErrorMessage("无法读取文件: \(error.localizedDescription)")
        }
    }

    /// 通过文件选择面板导入
    func selectFile() async {
        let urls = await AudioFileService.openFilePicker()
        guard let url = urls.first else { return }
        await loadFile(url: url)
    }

    // MARK: - 播放控制

    /// 开始或恢复播放
    func play() async {
        guard let fileURL = currentFile else { return }

        if isFinished {
            // 播放完毕后重新开始
            await seek(to: 0)
            return
        }

        if isPlaying {
            return
        }

        isLoading = true
        isFinished = false
        allDataRead = false

        do {
            // 创建流式降噪引擎
            let newDenoiser = try StreamingDenoiser()

            // 根据是否启用降噪选择不同的启动方式
            if denoiseEnabled {
                try newDenoiser.start(
                    inputURL: fileURL,
                    strength: Float(denoiseStrength),
                    startTime: seekOffset,
                    isVideo: isVideo
                )
            } else {
                try newDenoiser.startOriginal(
                    inputURL: fileURL,
                    startTime: seekOffset,
                    isVideo: isVideo
                )
            }
            self.denoiser = newDenoiser

            // 创建音频播放引擎
            let newPlayer = AudioEnginePlayer()
            try newPlayer.setup(format: StreamingDenoiser.outputFormat)
            newPlayer.volume = Float(volume)
            self.audioPlayer = newPlayer

            // 后台读取队列
            let queue = DispatchQueue(label: "com.voiceclean.streaming", qos: .userInitiated)
            self.readQueue = queue
            self.shouldContinueReading = true

            // 预填充 buffer
            var prefilled = 0
            for _ in 0..<prefillBufferCount {
                if let buffer = newDenoiser.readNextBuffer() {
                    newPlayer.scheduleBuffer(buffer)
                    prefilled += 1
                } else {
                    break
                }
            }

            guard prefilled > 0 else {
                throw StreamingDenoiserError.processLaunchFailed("无法读取音频数据")
            }

            // 开始播放
            newPlayer.play()
            isPlaying = true
            isLoading = false

            // 视频同步播放
            if isVideo, let avPlayer {
                let seekTime = CMTime(seconds: seekOffset, preferredTimescale: 600)
                await avPlayer.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
                avPlayer.play()
            }

            // 启动后台持续读取
            startReadingLoop(denoiser: newDenoiser, player: newPlayer, queue: queue)

            // 启动时间更新定时器
            startTimeUpdateTimer()

        } catch {
            isLoading = false
            showErrorMessage("播放失败: \(error.localizedDescription)")
        }
    }

    /// 暂停播放
    func pause() {
        shouldContinueReading = false
        audioPlayer?.pause()
        avPlayer?.pause()
        timeUpdateTimer?.invalidate()
        timeUpdateTimer = nil
        isPlaying = false

        // 记录当前时间作为下次 seek 偏移
        seekOffset = currentTime
        cleanupPlayback()
    }

    /// 停止播放并完全清理
    func stop() {
        shouldContinueReading = false
        timeUpdateTimer?.invalidate()
        timeUpdateTimer = nil

        audioPlayer?.stop()
        audioPlayer = nil

        denoiser?.stop()
        denoiser = nil

        avPlayer?.pause()
        avPlayer?.seek(to: .zero)

        readQueue = nil
        isPlaying = false
        isLoading = false
        currentTime = 0
        seekOffset = 0
        isFinished = false
        allDataRead = false
    }

    /// 跳转到指定时间
    func seek(to time: TimeInterval) async {
        let wasPlaying = isPlaying
        let clampedTime = max(0, min(time, duration))

        // 停止当前播放
        shouldContinueReading = false
        timeUpdateTimer?.invalidate()
        timeUpdateTimer = nil
        audioPlayer?.stop()
        audioPlayer = nil
        denoiser?.stop()
        denoiser = nil
        readQueue = nil
        isPlaying = false

        // 更新偏移
        seekOffset = clampedTime
        currentTime = clampedTime
        isFinished = false

        // 如果之前在播放，重新开始
        if wasPlaying {
            await play()
        }
    }

    // MARK: - 私有方法

    /// 启动后台持续读取循环
    private func startReadingLoop(
        denoiser: StreamingDenoiser,
        player: AudioEnginePlayer,
        queue: DispatchQueue
    ) {
        queue.async { [weak self] in
            while let self {
                guard self.shouldContinueReading else { break }
                guard let buffer = denoiser.readNextBuffer() else {
                    // EOF：所有数据已读取，但不停止播放
                    // 让定时器检测 playerNode 是否真正播完
                    DispatchQueue.main.async {
                        self.allDataRead = true
                    }
                    return
                }
                player.scheduleBuffer(buffer)
            }
        }
    }

    /// 当所有 buffer 播放完毕时的清理
    private func onPlaybackFinished() {
        isPlaying = false
        isFinished = true
        currentTime = duration
        timeUpdateTimer?.invalidate()
        timeUpdateTimer = nil
        avPlayer?.pause()
        cleanupPlayback()
    }

    /// 启动定时器更新播放时间
    private func startTimeUpdateTimer() {
        timeUpdateTimer?.invalidate()
        timeUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                if let player = self.audioPlayer {
                    let engineTime = player.currentTime
                    self.currentTime = self.seekOffset + max(0, engineTime)

                    // 防止超出总时长
                    if self.currentTime >= self.duration {
                        self.currentTime = self.duration
                    }

                    // 检测是否真正播放完毕：
                    // 所有数据已读取 且 playerNode 已停止播放（所有 buffer 消耗完毕）
                    if self.allDataRead && !player.isPlaying {
                        self.onPlaybackFinished()
                    }
                }
            }
        }
    }

    /// 清理播放资源（保留文件和 avPlayer）
    private func cleanupPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        denoiser?.stop()
        denoiser = nil
        readQueue = nil
    }

    /// 显示错误消息
    private func showErrorMessage(_ message: String) {
        errorMessage = message
        showError = true
    }

    // MARK: - 计算属性

    /// 是否已加载文件
    var hasFile: Bool {
        currentFile != nil
    }

    /// 格式化当前时间
    var formattedCurrentTime: String {
        Self.formatTime(currentTime)
    }

    /// 格式化总时长
    var formattedDuration: String {
        Self.formatTime(duration)
    }

    /// 播放进度 (0.0 ~ 1.0)
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1.0, currentTime / duration)
    }

    // MARK: - 工具方法

    /// 时间格式化
    private static func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = Int(max(0, time))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
