//
//  PlayerViewModel.swift
//  VoiceClear
//
//  Created by jxing on 2026/2/15.
//

import AVFoundation
import Foundation
import Observation

private final class ReadLoopController: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func setRunning(_ value: Bool) {
        lock.lock()
        running = value
        lock.unlock()
    }
}

@Observable
@MainActor
final class PlayerViewModel {

    // MARK: - Public State

    var currentFile: URL?
    var fileName: String = ""
    var isVideo: Bool = false
    var duration: TimeInterval = 0
    var currentTime: TimeInterval = 0
    var isPlaying: Bool = false
    var isLoading: Bool = false
    var denoiseStrength: Double = 1.0 {
        didSet { remoteTapProcessor?.updateStrength(Float(denoiseStrength)) }
    }
    var denoiseEnabled: Bool = true {
        didSet { remoteTapProcessor?.setEnabled(denoiseEnabled) }
    }
    var volume: Double = 1.0 {
        didSet {
            audioPlayer?.volume = Float(volume)
            avPlayer?.volume = Float(volume)
        }
    }
    var isFinished: Bool = false
    var errorMessage: String?
    var showError: Bool = false

    var urlInputText: String = ""
    var isDownloading: Bool = false

    /// 在线路径运行状态，便于 UI/日志观测。
    var streamStatusText: String = ""

    #if os(iOS)
    var showFilePicker: Bool = false
    var showPhotoPicker: Bool = false
    var isImporting: Bool = false
    #endif

    var avPlayer: AVPlayer?

    // MARK: - Playback Metrics / Gates

    struct PlaybackMetrics {
        var playRequestAt: Date?
        var firstFrameAt: Date?
        var startupLatencyMs: Double?
        var fallbackReason: String?
        var usedPassthrough: Bool = false
    }

    struct ReleaseGateThreshold {
        let startupLatencyMs: Double = 800
    }

    var playbackMetrics = PlaybackMetrics()
    let releaseGate = ReleaseGateThreshold()

    // MARK: - Private State

    private enum PlaybackPath {
        case localEngine
        case remoteAVPlayer
    }

    private var playbackPath: PlaybackPath = .localEngine
    private var pipelineMode: StreamingPipelineMode = .incrementalAVFoundation

    private var denoiser: StreamingAudioPipeline?
    private var audioPlayer: AudioEnginePlayer?
    private var remoteTapProcessor: AVPlayerDenoiseTapProcessor?

    private var readQueue: DispatchQueue?
    private var timeUpdateTimer: Timer?
    private var hasSecurityScopedAccess: Bool = false
    private var allDataRead: Bool = false
    private var seekOffset: TimeInterval = 0
    private var lastDriftCorrectionTime: TimeInterval = 0
    private var isRemoteStream = false

    private let maxBufferedDuration: TimeInterval = 2.0
    private let readLoopController = ReadLoopController()

    // MARK: - File loading

    func loadFile(url: URL) async {
        stop()

        let ext = url.pathExtension.lowercased()
        guard kAllSupportedExtensions.contains(ext) else {
            showErrorMessage(String(format: String(localized: "Unsupported format: .%@"), ext))
            return
        }

        let securityScoped = url.startAccessingSecurityScopedResource()
        do {
            let fileDuration = try AudioFileService.getMediaDuration(url: url)
            currentFile = url
            hasSecurityScopedAccess = securityScoped
            fileName = url.lastPathComponent
            isVideo = kVideoExtensions.contains(ext)
            duration = fileDuration
            currentTime = 0
            seekOffset = 0
            isFinished = false
            isRemoteStream = false
            streamStatusText = String(localized: "本地文件模式")

            if isVideo {
                let player = AVPlayer(url: url)
                player.isMuted = true
                player.automaticallyWaitsToMinimizeStalling = false
                avPlayer = player
            } else {
                avPlayer = nil
            }
            playbackPath = .localEngine
        } catch {
            if securityScoped { url.stopAccessingSecurityScopedResource() }
            showErrorMessage(String(format: String(localized: "Cannot read file: %@"), error.localizedDescription))
        }
    }

    func loadFromURL() async {
        let trimmed = urlInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showErrorMessage(String(localized: "Please enter a valid URL"))
            return
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            showErrorMessage(String(localized: "Please enter a valid HTTP/HTTPS URL"))
            return
        }

        isDownloading = true
        streamStatusText = String(localized: "在线资源加载中...")
        defer { isDownloading = false }
        do {
            try await prepareRemoteStream(url: url)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorFileDoesNotExist {
                showErrorMessage(String(localized: "在线资源不存在或已过期，请更换可访问的音频地址"))
                clearLoadedMediaState()
                return
            }
            // 回退到旧模式：下载后本地播放，保障可用性。
            do {
                playbackMetrics.fallbackReason = "remote_stream_prepare_failed"
                streamStatusText = String(localized: "回退：下载后播放")
                let localURL = try await downloadRemoteFile(from: url)
                await loadFile(url: localURL)
            } catch {
                showErrorMessage(String(format: String(localized: "Download failed: %@"), error.localizedDescription))
                clearLoadedMediaState()
            }
        }
    }

    private func prepareRemoteStream(url: URL) async throws {
        stop()
        currentFile = url
        fileName = url.lastPathComponent.isEmpty ? String(localized: "Online Stream") : url.lastPathComponent
        currentTime = 0
        seekOffset = 0
        isFinished = false
        isRemoteStream = true
        playbackPath = .remoteAVPlayer

        let ext = url.pathExtension.lowercased()
        isVideo = kVideoExtensions.contains(ext)

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.volume = Float(volume)
        player.automaticallyWaitsToMinimizeStalling = true

        if denoiseEnabled {
            do {
                let tap = AVPlayerDenoiseTapProcessor(
                    strength: Float(denoiseStrength),
                    enabled: true
                )
                try await tap.attach(to: item)
                remoteTapProcessor = tap
                streamStatusText = String(localized: "在线真流式（降噪）")
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorFileDoesNotExist {
                    throw error
                }
                remoteTapProcessor = nil
                playbackMetrics.usedPassthrough = true
                playbackMetrics.fallbackReason = "audio_tap_attach_failed"
                streamStatusText = String(localized: "在线真流式（原声）")
            }
        } else {
            remoteTapProcessor = nil
            streamStatusText = String(localized: "在线真流式（原声）")
        }

        avPlayer = player
        let seconds: TimeInterval
        if #available(iOS 16.0, macOS 13.0, *) {
            if let loaded = try? await item.asset.load(.duration) {
                seconds = loaded.seconds
            } else {
                seconds = 0
            }
        } else {
            seconds = item.asset.duration.seconds
        }
        duration = seconds.isFinite && seconds > 0 ? seconds : 0
    }

    func selectFile() async {
        #if os(macOS)
        let urls = await AudioFileService.openFilePicker()
        guard let url = urls.first else { return }
        await loadFile(url: url)
        #else
        showFilePicker = true
        #endif
    }

    // MARK: - Playback controls

    func play() async {
        guard currentFile != nil else { return }
        if isFinished {
            await seek(to: 0)
            return
        }
        if isPlaying { return }

        playbackMetrics.playRequestAt = Date()
        playbackMetrics.firstFrameAt = nil
        playbackMetrics.startupLatencyMs = nil
        isLoading = true
        if isRemoteStream {
            await playRemoteStream()
            return
        }
        await playLocalStream()
    }

    private func playRemoteStream() async {
        guard let avPlayer else {
            isLoading = false
            showErrorMessage(String(localized: "Remote player unavailable"))
            return
        }

        let start = CMTime(seconds: seekOffset, preferredTimescale: 600)
        await avPlayer.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
        avPlayer.play()
        isPlaying = true
        isLoading = false
        startTimeUpdateTimer()
    }

    private func playLocalStream() async {
        guard let fileURL = currentFile else {
            isLoading = false
            return
        }

        do {
            let pipeline = makePipeline()
            if denoiseEnabled {
                try pipeline.start(
                    inputURL: fileURL,
                    strength: Float(denoiseStrength),
                    startTime: seekOffset,
                    maxDuration: nil,
                    isVideo: isVideo
                )
            } else {
                try pipeline.startOriginal(
                    inputURL: fileURL,
                    startTime: seekOffset,
                    maxDuration: nil,
                    isVideo: isVideo
                )
            }

            let player = AudioEnginePlayer()
            try player.setup(format: pipeline.playbackFormat)
            player.volume = Float(volume)

            denoiser = pipeline
            audioPlayer = player
            readLoopController.setRunning(true)
            allDataRead = false

            let prefillTarget = preferredPrefillDuration()
            var prefilled: TimeInterval = 0
            let prefillDeadline = Date().addingTimeInterval(2.0)

            while prefilled < prefillTarget, Date() < prefillDeadline {
                if let buffer = pipeline.readNextBuffer() {
                    player.scheduleBuffer(buffer)
                    prefilled += TimeInterval(buffer.frameLength) / pipeline.playbackFormat.sampleRate
                } else if !pipeline.isRunning {
                    break
                } else {
                    try? await Task.sleep(nanoseconds: 8_000_000)
                }
            }

            guard prefilled > 0 else {
                throw NSError(domain: "PlayerViewModel", code: -2, userInfo: [
                    NSLocalizedDescriptionKey: String(localized: "Cannot read audio data")
                ])
            }

            if isVideo, let avPlayer {
                let seekTime = CMTime(seconds: seekOffset, preferredTimescale: 600)
                await avPlayer.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
                avPlayer.play()
            }
            player.play()

            isPlaying = true
            isLoading = false
            startTimeUpdateTimer()

            let queue = DispatchQueue(label: "com.voiceclear.streaming.local", qos: .userInitiated)
            readQueue = queue
            startReadingLoop(
                denoiser: pipeline,
                player: player,
                queue: queue
            )
        } catch {
            isLoading = false
            showErrorMessage(String(format: String(localized: "Playback failed: %@"), error.localizedDescription))
        }
    }

    func pause() {
        seekOffset = currentTime
        readLoopController.setRunning(false)
        audioPlayer?.pause()
        avPlayer?.pause()
        timeUpdateTimer?.invalidate()
        timeUpdateTimer = nil
        isPlaying = false
    }

    func stop() {
        readLoopController.setRunning(false)
        timeUpdateTimer?.invalidate()
        timeUpdateTimer = nil

        audioPlayer?.stop()
        audioPlayer = nil
        denoiser?.stop()
        denoiser = nil
        remoteTapProcessor = nil
        readQueue = nil

        avPlayer?.pause()
        avPlayer?.seek(to: .zero)

        if hasSecurityScopedAccess, let url = currentFile {
            url.stopAccessingSecurityScopedResource()
            hasSecurityScopedAccess = false
        }

        isPlaying = false
        isLoading = false
        currentTime = 0
        seekOffset = 0
        isFinished = false
        allDataRead = false
    }

    func seek(to time: TimeInterval) async {
        let bounded = max(0, min(time, duration > 0 ? duration : time))
        let wasPlaying = isPlaying
        pause()
        currentTime = bounded
        seekOffset = bounded
        isFinished = false

        if isRemoteStream {
            if let avPlayer {
                let target = CMTime(seconds: bounded, preferredTimescale: 600)
                await avPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            if wasPlaying { await play() }
            return
        }

        if wasPlaying {
            await play()
        }
    }

    // MARK: - Internal playback loop

    private func startReadingLoop(
        denoiser: StreamingAudioPipeline,
        player: AudioEnginePlayer,
        queue: DispatchQueue
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            while self.readLoopController.isRunning {
                if player.bufferedDuration >= self.maxBufferedDuration {
                    Thread.sleep(forTimeInterval: 0.02)
                    continue
                }

                if let buffer = denoiser.readNextBuffer() {
                    player.scheduleBuffer(buffer)
                    continue
                }

                if !denoiser.isRunning {
                    DispatchQueue.main.async {
                        self.allDataRead = true
                    }
                    break
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    private func preferredPrefillDuration() -> TimeInterval {
        if isVideo { return 0.35 }
        return 0.2
    }

    private func makePipeline() -> StreamingAudioPipeline {
        switch pipelineMode {
        case .incrementalAVFoundation:
            return IncrementalStreamingDenoiser()
        case .legacyChunked:
            return StreamingDenoiser()
        }
    }

    private func onPlaybackFinished() {
        isPlaying = false
        isFinished = true
        if duration > 0 { currentTime = duration }
        timeUpdateTimer?.invalidate()
        timeUpdateTimer = nil
        avPlayer?.pause()
        cleanupPlayback()
    }

    private func startTimeUpdateTimer() {
        timeUpdateTimer?.invalidate()
        lastDriftCorrectionTime = ProcessInfo.processInfo.systemUptime
        timeUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }

                switch self.playbackPath {
                case .remoteAVPlayer:
                    if let avPlayer = self.avPlayer {
                        self.currentTime = max(0, avPlayer.currentTime().seconds)
                        let total = avPlayer.currentItem?.duration.seconds ?? self.duration
                        if total.isFinite && total > 0 {
                            self.duration = total
                            if self.currentTime >= total - 0.05 && avPlayer.rate == 0 {
                                self.onPlaybackFinished()
                            }
                        }
                        self.captureStartupLatencyIfNeeded()
                    }

                case .localEngine:
                    if let player = self.audioPlayer {
                        let engineTime = player.currentTime
                        self.currentTime = self.seekOffset + max(0, engineTime)
                        if self.currentTime >= self.duration, self.duration > 0 {
                            self.currentTime = self.duration
                        }

                        if self.isVideo, let avPlayer = self.avPlayer, avPlayer.rate > 0 {
                            let videoTime = avPlayer.currentTime().seconds
                            let drift = self.currentTime - videoTime
                            let now = ProcessInfo.processInfo.systemUptime
                            if abs(drift) > 0.1 && (now - self.lastDriftCorrectionTime) > 2 {
                                let target = CMTime(seconds: self.currentTime, preferredTimescale: 600)
                                avPlayer.seek(
                                    to: target,
                                    toleranceBefore: CMTimeMakeWithSeconds(0.1, preferredTimescale: 600),
                                    toleranceAfter: CMTimeMakeWithSeconds(0.1, preferredTimescale: 600)
                                )
                                self.lastDriftCorrectionTime = now
                            }
                        }

                        if self.allDataRead && player.bufferedDuration <= 0 {
                            self.onPlaybackFinished()
                        }
                        self.captureStartupLatencyIfNeeded()
                    }
                }
            }
        }
    }

    private func captureStartupLatencyIfNeeded() {
        guard playbackMetrics.firstFrameAt == nil, currentTime > 0 else { return }
        playbackMetrics.firstFrameAt = Date()
        if let start = playbackMetrics.playRequestAt {
            let ms = Date().timeIntervalSince(start) * 1000
            playbackMetrics.startupLatencyMs = ms
            if ms > releaseGate.startupLatencyMs {
                streamStatusText = String(localized: "首帧偏慢，建议回退策略")
            }
        }
    }

    private func cleanupPlayback() {
        let playerToStop = audioPlayer
        let denoiserToStop = denoiser
        audioPlayer = nil
        denoiser = nil
        readQueue = nil
        remoteTapProcessor = nil

        DispatchQueue.global(qos: .utility).async {
            playerToStop?.stop()
            denoiserToStop?.stop()
        }
    }

    // MARK: - Remote download fallback

    private func downloadRemoteFile(from url: URL) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: url)

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw NSError(domain: "PlayerViewModel", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: String(format: String(localized: "Server returned error (%d)"), httpResponse.statusCode)
            ])
        }

        var ext = url.pathExtension.lowercased()
        if ext.isEmpty || !kAllSupportedExtensions.contains(ext) {
            if let mimeType = response.mimeType?.lowercased() {
                ext = Self.extensionForMIMEType(mimeType)
            }
        }

        let destURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vc_online_\(UUID().uuidString)")
            .appendingPathExtension(ext)
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destURL)
        return destURL
    }

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

    private func showErrorMessage(_ message: String) {
        errorMessage = message
        showError = true
    }

    /// 仅清理“已加载媒体”相关状态，保留用户输入和错误提示。
    private func clearLoadedMediaState() {
        currentFile = nil
        fileName = ""
        isVideo = false
        duration = 0
        currentTime = 0
        seekOffset = 0
        isFinished = false
        allDataRead = false
        isRemoteStream = false
        playbackPath = .localEngine
        streamStatusText = ""
        remoteTapProcessor = nil
        avPlayer = nil
        denoiser = nil
        audioPlayer = nil
        readLoopController.setRunning(false)
    }

    // MARK: - Computed

    var hasFile: Bool { currentFile != nil }
    var formattedCurrentTime: String { Self.formatTime(currentTime) }
    var formattedDuration: String { Self.formatTime(duration) }
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1.0, currentTime / duration)
    }

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
