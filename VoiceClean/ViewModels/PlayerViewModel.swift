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
    var denoiseStrength: Double = 1.0

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

    // MARK: - 在线文件

    /// URL 输入框文本
    var urlInputText: String = ""

    /// 是否正在下载在线文件
    var isDownloading: Bool = false

    // MARK: - iOS 文件选择状态

    #if os(iOS)
    /// 是否展示文件选择器
    var showFilePicker: Bool = false

    /// 是否展示相册选择器
    var showPhotoPicker: Bool = false

    /// 是否正在从相册导入文件
    var isImporting: Bool = false
    #endif

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

    /// 是否已获取安全作用域访问权限（iOS 文件选择器返回的 URL 需要）
    private var hasSecurityScopedAccess: Bool = false

    /// 标记 FFmpeg 数据已全部读取完毕（但音频可能仍在播放）
    private var allDataRead: Bool = false

    /// 每次按小段预降噪的时长（秒）
    private let chunkDuration: TimeInterval = 4.0

    /// 播放启动前最少预填充时长（秒）
    private let initialPrefillDuration: TimeInterval = 0.8

    /// 后台读取时允许的最大预缓冲时长（秒）
    private let maxBufferedDuration: TimeInterval = 2.0

    /// 当前应处理的下一段起始时间（秒）
    private var nextChunkStartTime: TimeInterval = 0

    // MARK: - 文件管理

    /// 加载媒体文件
    func loadFile(url: URL) async {
        // 清理之前的播放状态（会释放旧文件的安全作用域）
        stop()

        let ext = url.pathExtension.lowercased()
        guard kAllSupportedExtensions.contains(ext) else {
            showErrorMessage("不支持的文件格式: .\(ext)")
            return
        }

        // iOS fileImporter 返回的 URL 是安全作用域资源，必须先获取访问权限
        let securityScoped = url.startAccessingSecurityScopedResource()

        do {
            let fileDuration = try AudioFileService.getMediaDuration(url: url)

            self.currentFile = url
            self.hasSecurityScopedAccess = securityScoped
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
            // 加载失败，释放安全作用域
            if securityScoped { url.stopAccessingSecurityScopedResource() }
            showErrorMessage("无法读取文件: \(error.localizedDescription)")
        }
    }

    /// 从在线 URL 加载文件
    func loadFromURL() async {
        let trimmed = urlInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showErrorMessage("请输入有效的 URL")
            return
        }

        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            showErrorMessage("请输入有效的 HTTP/HTTPS 地址")
            return
        }

        isDownloading = true

        do {
            let localURL = try await downloadRemoteFile(from: url)
            await loadFile(url: localURL)
        } catch {
            showErrorMessage("下载失败: \(error.localizedDescription)")
        }

        isDownloading = false
    }

    /// 通过文件选择面板导入
    func selectFile() async {
        #if os(macOS)
        let urls = await AudioFileService.openFilePicker()
        guard let url = urls.first else { return }
        await loadFile(url: url)
        #else
        showFilePicker = true
        #endif
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
        nextChunkStartTime = seekOffset

        do {
            // 创建流式降噪引擎
            let newDenoiser = try StreamingDenoiser()

            // 只启动首个小段，而不是整段文件
            let initialChunkDuration = min(chunkDuration, max(0, duration - nextChunkStartTime))
            try startDenoiserChunk(
                denoiser: newDenoiser,
                fileURL: fileURL,
                startTime: nextChunkStartTime,
                chunkDuration: initialChunkDuration
            )
            nextChunkStartTime += initialChunkDuration
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

            // 预填充：只准备即将播放的一小段
            let prefilledDuration = try prefillInitialBuffers(
                denoiser: newDenoiser,
                player: newPlayer,
                fileURL: fileURL
            )

            guard prefilledDuration > 0 else {
                throw NSError(domain: "PlayerViewModel", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "无法读取音频数据"
                ])
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
            startReadingLoop(
                denoiser: newDenoiser,
                player: newPlayer,
                queue: queue,
                fileURL: fileURL
            )

            // 启动时间更新定时器
            startTimeUpdateTimer()

        } catch {
            isLoading = false
            showErrorMessage("播放失败: \(error.localizedDescription)")
        }
    }

    /// 暂停播放
    func pause() {
        // 记录当前时间作为下次 seek 偏移
        seekOffset = currentTime

        // 先标记停止读取，后台线程会自行退出并调用 activeDenoiser.stop()
        shouldContinueReading = false
        audioPlayer?.pause()
        avPlayer?.pause()
        timeUpdateTimer?.invalidate()
        timeUpdateTimer = nil
        isPlaying = false

        // 将阻塞性的清理操作移到后台队列，避免阻塞主线程
        let playerToStop = audioPlayer
        let denoiserToStop = denoiser
        audioPlayer = nil
        denoiser = nil
        readQueue = nil

        DispatchQueue.global(qos: .utility).async {
            playerToStop?.stop()
            denoiserToStop?.stop()
        }
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

        // 释放安全作用域访问权限
        if hasSecurityScopedAccess, let url = currentFile {
            url.stopAccessingSecurityScopedResource()
            hasSecurityScopedAccess = false
        }

        readQueue = nil
        isPlaying = false
        isLoading = false
        currentTime = 0
        seekOffset = 0
        isFinished = false
        allDataRead = false
        nextChunkStartTime = 0
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
        allDataRead = false

        // 更新偏移
        seekOffset = clampedTime
        currentTime = clampedTime
        isFinished = false
        nextChunkStartTime = clampedTime

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
        queue: DispatchQueue,
        fileURL: URL
    ) {
        queue.async { [weak self] in
            var activeDenoiser = denoiser
            while let self {
                guard self.shouldContinueReading else { break }

                // 仅保持小窗口预缓冲，避免提前处理整段文件
                if player.bufferedDuration >= self.maxBufferedDuration {
                    Thread.sleep(forTimeInterval: 0.03)
                    continue
                }

                if let buffer = activeDenoiser.readNextBuffer() {
                    player.scheduleBuffer(buffer)
                    continue
                }

                activeDenoiser.stop()

                // 当前 chunk 已读完，按播放位置继续处理下一小段
                let remaining = self.duration - self.nextChunkStartTime
                guard remaining > 0.01 else {
                    DispatchQueue.main.async {
                        self.allDataRead = true
                    }
                    return
                }

                let nextDuration = min(self.chunkDuration, remaining)
                do {
                    let nextDenoiser = try StreamingDenoiser()
                    try self.startDenoiserChunk(
                        denoiser: nextDenoiser,
                        fileURL: fileURL,
                        startTime: self.nextChunkStartTime,
                        chunkDuration: nextDuration
                    )
                    self.nextChunkStartTime += nextDuration
                    self.denoiser = nextDenoiser
                    activeDenoiser = nextDenoiser
                } catch {
                    DispatchQueue.main.async {
                        self.showErrorMessage("播放失败: \(error.localizedDescription)")
                        self.pause()
                    }
                    return
                }
            }
            activeDenoiser.stop()
        }
    }

    /// 播放前预填充少量数据，避免起播卡顿
    private func prefillInitialBuffers(
        denoiser: StreamingDenoiser,
        player: AudioEnginePlayer,
        fileURL: URL
    ) throws -> TimeInterval {
        var buffered: TimeInterval = 0
        var activeDenoiser = denoiser

        while buffered < initialPrefillDuration {
            if let buffer = activeDenoiser.readNextBuffer() {
                player.scheduleBuffer(buffer)
                buffered += TimeInterval(buffer.frameLength) / StreamingDenoiser.sampleRate
                continue
            }

            activeDenoiser.stop()
            let remaining = duration - nextChunkStartTime
            guard remaining > 0.01 else { break }

            let nextDuration = min(chunkDuration, remaining)
            let nextDenoiser = try StreamingDenoiser()
            try startDenoiserChunk(
                denoiser: nextDenoiser,
                fileURL: fileURL,
                startTime: nextChunkStartTime,
                chunkDuration: nextDuration
            )
            nextChunkStartTime += nextDuration
            self.denoiser = nextDenoiser
            activeDenoiser = nextDenoiser
        }

        return buffered
    }

    /// 启动一个指定区间的小段降噪（或原始）读取
    private func startDenoiserChunk(
        denoiser: StreamingDenoiser,
        fileURL: URL,
        startTime: TimeInterval,
        chunkDuration: TimeInterval
    ) throws {
        if denoiseEnabled {
            try denoiser.start(
                inputURL: fileURL,
                strength: Float(denoiseStrength),
                startTime: startTime,
                maxDuration: chunkDuration,
                isVideo: isVideo
            )
        } else {
            try denoiser.startOriginal(
                inputURL: fileURL,
                startTime: startTime,
                maxDuration: chunkDuration,
                isVideo: isVideo
            )
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
                    // 所有数据已读取 且 所有已调度的 buffer 均已消耗完毕
                    // 注意：不能用 playerNode.isPlaying，它只反映 play/stop 状态，
                    // 即使所有 buffer 都播完了，isPlaying 仍然为 true。
                    if self.allDataRead && player.bufferedDuration <= 0 {
                        self.onPlaybackFinished()
                    }
                }
            }
        }
    }

    /// 清理播放资源（保留文件和 avPlayer），非阻塞
    private func cleanupPlayback() {
        let playerToStop = audioPlayer
        let denoiserToStop = denoiser
        audioPlayer = nil
        denoiser = nil
        readQueue = nil

        DispatchQueue.global(qos: .utility).async {
            playerToStop?.stop()
            denoiserToStop?.stop()
        }
    }

    /// 下载远程文件到临时目录
    private func downloadRemoteFile(from url: URL) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: url)

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw NSError(domain: "PlayerViewModel", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "服务器返回错误 (\(httpResponse.statusCode))"
            ])
        }

        // 从 URL 路径获取文件扩展名，回退到 MIME 类型推断
        var ext = url.pathExtension.lowercased()
        if ext.isEmpty || !kAllSupportedExtensions.contains(ext) {
            if let mimeType = response.mimeType?.lowercased() {
                ext = Self.extensionForMIMEType(mimeType)
            }
        }

        let destURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vc_online_\(UUID().uuidString)")
            .appendingPathExtension(ext)

        // download(from:) 返回的临时文件需移动到我们的目标位置
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destURL)

        return destURL
    }

    /// 根据 MIME 类型推断文件扩展名
    private static func extensionForMIMEType(_ mimeType: String) -> String {
        let mapping: [String: String] = [
            "audio/mpeg": "mp3",
            "audio/mp3": "mp3",
            "audio/mp4": "m4a",
            "audio/x-m4a": "m4a",
            "audio/aac": "aac",
            "audio/wav": "wav",
            "audio/x-wav": "wav",
            "audio/aiff": "aiff",
            "audio/x-aiff": "aiff",
            "audio/flac": "flac",
            "video/mp4": "mp4",
            "video/quicktime": "mov",
        ]
        return mapping[mimeType] ?? "mp3"
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
