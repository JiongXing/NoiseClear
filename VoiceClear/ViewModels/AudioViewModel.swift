//
//  AudioViewModel.swift
//  VoiceClear
//
//  Created by jxing on 2026/2/12.
//

import Foundation
import Observation
import UniformTypeIdentifiers

// MARK: - 主 ViewModel

/// 管理音频文件列表和降噪处理的核心 ViewModel
@Observable
@MainActor
final class AudioViewModel {

    // MARK: - 公开状态

    /// 已添加的音频文件列表
    var audioFiles: [AudioFileItem] = []

    /// 是否正在处理
    var isProcessing: Bool = false

    /// 降噪强度 (0.0 ~ 1.0)
    var denoiseStrength: Double = 1.0

    /// 全局错误消息（用于 Alert 展示）
    var errorMessage: String?
    var showError: Bool = false

    /// 当前选中的文件 ID（用于详情/波形展示）
    var selectedFileID: UUID?

    /// 当前文件处理开始时间（用于剩余时间预估）
    var processingStartTime: Date?

    /// 预估剩余时间（秒），进度不足时不展示
    var estimatedRemainingSeconds: Double?

    /// 是否正在导入并预处理文件（读取时长/波形）
    var isImportingFiles: Bool = false

    /// 文件导入预处理进度 (0.0 ~ 1.0)
    var importProgress: Double = 0

    /// 当前导入中的文件名（用于 UI 提示）
    var importingFileName: String?

    private var importTask: Task<Void, Never>?
    private var shouldStopProcessing: Bool = false
    private var activeDenoiser: FFmpegDenoiser?

    // MARK: - iOS 文件选择与导出状态

    #if os(iOS)
    /// 是否展示文件选择器（由 View 层 .fileImporter 绑定）
    var showFilePicker: Bool = false

    /// 是否展示分享面板（由 View 层 .sheet 绑定）
    var showShareSheet: Bool = false

    /// 待导出的文件 URL 列表（用于分享面板）
    var pendingExportURLs: [URL] = []

    /// 是否展示相册选择器
    var showPhotoPicker: Bool = false

    /// 是否正在从相册导入文件
    var isImporting: Bool = false
    #endif

    // MARK: - 计算属性

    /// 是否有文件可以处理
    var hasFilesToProcess: Bool {
        audioFiles.contains { file in
            guard file.importStatus.isReady else { return false }
            if case .idle = file.status { return true }
            if case .failed = file.status { return true }
            return false
        }
    }

    /// 是否有文件已完成处理
    var hasCompletedFiles: Bool {
        audioFiles.contains { $0.status.isCompleted }
    }

    /// 整体处理进度
    var overallProgress: Double {
        guard !audioFiles.isEmpty else { return 0 }
        let total = audioFiles.reduce(0.0) { sum, file in
            switch file.status {
            case .completed: return sum + 1.0
            case .processing(let p): return sum + p
            default: return sum
            }
        }
        return total / Double(audioFiles.count)
    }

    // MARK: - 文件管理

    /// 通过文件选择面板添加文件
    func addFiles() async {
        #if os(macOS)
        let urls = await AudioFileService.openFilePicker()
        await addFiles(from: urls)
        #else
        showFilePicker = true
        #endif
    }

    /// 通过 URL 列表添加文件（支持拖拽）
    func addFiles(from urls: [URL]) async {
        guard !urls.isEmpty else { return }

        let candidates = urls.filter { url in
            let ext = url.pathExtension.lowercased()
            guard kAllSupportedExtensions.contains(ext) else { return false }
            return !audioFiles.contains(where: { $0.url == url })
        }
        guard !candidates.isEmpty else { return }

        importTask?.cancel()

        // 阶段一：立即入列，占位展示，提升交互响应速度。
        for url in candidates {
            let placeholder = AudioFileItem(
                url: url,
                duration: 0,
                waveformSamples: [],
                importStatus: .loading
            )
            audioFiles.append(placeholder)
        }

        isImportingFiles = true
        importProgress = 0
        importingFileName = nil

        importTask = Task { @MainActor in
            let totalCount = Double(candidates.count)
            var handledCount: Double = 0

            defer {
                self.isImportingFiles = false
                self.importProgress = 0
                self.importingFileName = nil
                self.importTask = nil
            }

            for url in candidates {
                if Task.isCancelled { break }

                self.importingFileName = url.lastPathComponent

                // iOS fileImporter 返回的 URL 是安全作用域资源，必须先获取访问权限
                let securityScoped = url.startAccessingSecurityScopedResource()
                defer { if securityScoped { url.stopAccessingSecurityScopedResource() } }

                do {
                    let loaded = try await self.loadDurationAndWaveform(url: url)
                    if let index = self.audioFiles.firstIndex(where: { $0.url == url }) {
                        self.audioFiles[index].duration = loaded.duration
                        self.audioFiles[index].waveformSamples = loaded.waveform
                        self.audioFiles[index].importStatus = .ready
                    }
                } catch {
                    if let index = self.audioFiles.firstIndex(where: { $0.url == url }) {
                        self.audioFiles[index].importStatus = .failed(error.localizedDescription)
                    }
                    self.showErrorMessage(L10n.string(.conversionErrorCannotReadFileDetail, url.lastPathComponent, error.localizedDescription))
                }

                handledCount += 1
                self.importProgress = min(1.0, handledCount / totalCount)
            }
        }
    }

    /// 取消当前导入任务
    func cancelImport() {
        importTask?.cancel()
        importTask = nil
        isImportingFiles = false
        importProgress = 0
        importingFileName = nil

        // 保留成功导入的文件，移除仍在加载中的占位项。
        audioFiles.removeAll { $0.importStatus.isLoading }
    }

    /// 移除指定文件
    func removeFile(_ item: AudioFileItem) {
        audioFiles.removeAll { $0.id == item.id }
        if selectedFileID == item.id {
            selectedFileID = nil
        }
    }

    /// 移除所有文件
    func removeAll() {
        cancelImport()
        audioFiles.removeAll()
        selectedFileID = nil
    }

    // MARK: - 降噪处理

    /// 处理所有待处理的文件
    func processAll() async {
        guard !isProcessing else { return }
        shouldStopProcessing = false
        isProcessing = true
        defer {
            isProcessing = false
            shouldStopProcessing = false
            activeDenoiser = nil
        }

        for i in audioFiles.indices {
            if shouldStopProcessing { break }
            guard audioFiles[i].importStatus.isReady else { continue }

            let canRetry: Bool
            switch audioFiles[i].status {
            case .idle: canRetry = true
            case .failed: canRetry = true
            default: canRetry = false
            }
            guard canRetry else { continue }

            await processFile(at: i)
        }
    }

    /// 处理单个文件
    func processSingleFile(_ item: AudioFileItem) async {
        guard let index = audioFiles.firstIndex(where: { $0.id == item.id }) else { return }
        guard audioFiles[index].importStatus.isReady else { return }
        guard !isProcessing else { return }

        shouldStopProcessing = false
        isProcessing = true
        defer {
            isProcessing = false
            shouldStopProcessing = false
            activeDenoiser = nil
        }

        await processFile(at: index)
    }

    /// 停止当前降噪处理
    func stopProcessing() {
        shouldStopProcessing = true
        activeDenoiser?.cancel()
    }

    /// 导出单个已完成的文件
    func exportFile(_ item: AudioFileItem) async {
        guard case .completed(_) = item.status else { return }

        #if os(macOS)
        let baseName = (item.fileName as NSString).deletingPathExtension
        let suggestedName: String
        let allowedContentTypes: [UTType]

        if item.isVideo {
            let ext = item.fileExtension
            suggestedName = "\(baseName)_denoised.\(ext)"
            allowedContentTypes = ext == "mov" ? [.quickTimeMovie] : [.mpeg4Movie]
        } else {
            suggestedName = "\(baseName)_denoised.wav"
            allowedContentTypes = [.wav]
        }

        guard case .completed(let tempURL) = item.status else { return }
        guard let saveURL = await AudioFileService.openSavePanel(
            suggestedName: suggestedName,
            allowedContentTypes: allowedContentTypes
        ) else { return }

        do {
            try AudioFileService.exportFile(from: tempURL, to: saveURL)
        } catch {
            showErrorMessage(L10n.string(.conversionErrorExportFailed, error.localizedDescription))
        }
        #else
        guard case .completed(let tempURL) = item.status else { return }
        pendingExportURLs = [tempURL]
        showShareSheet = true
        #endif
    }

    /// 导出所有已完成的文件
    func exportAll() async {
        #if os(macOS)
        for item in audioFiles where item.status.isCompleted {
            await exportFile(item)
        }
        #else
        let urls = audioFiles.compactMap { item -> URL? in
            guard case .completed(let url) = item.status else { return nil }
            return url
        }
        guard !urls.isEmpty else { return }
        pendingExportURLs = urls
        showShareSheet = true
        #endif
    }

    // MARK: - 私有方法

    /// 处理指定索引的文件（使用 RNNoise 降噪）
    ///
    /// 音频文件：直接降噪输出 WAV
    /// 视频文件：复制视频流 + 降噪音频轨道，输出原格式（MP4/MOV）
    private func processFile(at index: Int) async {
        guard index < audioFiles.count else { return }
        guard audioFiles[index].importStatus.isReady else { return }

        audioFiles[index].status = .processing(0)
        processingStartTime = Date()
        estimatedRemainingSeconds = nil

        let inputURL = audioFiles[index].url
        let fileName = audioFiles[index].fileName
        let duration = audioFiles[index].duration
        let isVideo = audioFiles[index].isVideo
        let strength = Float(denoiseStrength)
        let fileIndex = index

        if shouldStopProcessing {
            audioFiles[index].status = .idle
            return
        }

        // iOS fileImporter 返回的 URL 是安全作用域资源，处理期间需保持访问权限
        let securityScoped = inputURL.startAccessingSecurityScopedResource()
        defer { if securityScoped { inputURL.stopAccessingSecurityScopedResource() } }

        do {
            // 生成输出临时文件 URL（视频保留原格式，音频输出 WAV）
            let outputURL = AudioFileService.generateTempOutputURL(
                originalFileName: fileName,
                isVideo: isVideo
            )

            // 所有重操作通过 GCD 在全局队列执行，确保不在主线程
            let denoiser = FFmpegDenoiser(strength: strength)
            activeDenoiser = denoiser

            let result: (waveform: [Float], tempURL: URL) = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        // 执行 RNNoise 降噪（根据文件类型选择不同处理策略）
                        try denoiser.process(
                            inputURL: inputURL,
                            outputURL: outputURL,
                            duration: duration,
                            isVideo: isVideo
                        ) { progress in
                            // 进度回调已在 FFmpegDenoiser 内节流至每 1%，主线程更新开销可接受
                            DispatchQueue.main.async {
                                guard fileIndex < self.audioFiles.count else { return }
                                self.audioFiles[fileIndex].status = .processing(progress)
                                self.updateEstimatedRemaining(progress: progress)
                            }
                        }

                        // 从降噪后的文件提取波形数据（视频文件会自动提取音频轨道）
                        let waveform = try AudioFileService.loadWaveformFromFile(url: outputURL)

                        continuation.resume(returning: (waveform, outputURL))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

            guard index < audioFiles.count else { return }
            audioFiles[index].processedWaveformSamples = result.waveform
            audioFiles[index].status = .completed(result.tempURL)
            processingStartTime = nil
            estimatedRemainingSeconds = nil
            activeDenoiser = nil

        } catch {
            activeDenoiser = nil
            guard index < audioFiles.count else { return }
            processingStartTime = nil
            estimatedRemainingSeconds = nil

            if let denoiserError = error as? FFmpegDenoiserError,
               case .cancelled = denoiserError {
                audioFiles[index].status = .idle
                return
            }
            if shouldStopProcessing {
                audioFiles[index].status = .idle
                return
            }

            audioFiles[index].status = .failed(error.localizedDescription)
            showErrorMessage(L10n.string(.conversionErrorProcessingFailed, audioFiles[index].fileName, error.localizedDescription))
        }
    }

    /// 根据进度更新剩余时间预估（指数平滑减小抖动）
    private func updateEstimatedRemaining(progress: Double) {
        guard progress >= 0.02, let start = processingStartTime else {
            estimatedRemainingSeconds = nil
            return
        }
        let elapsed = Date().timeIntervalSince(start)
        let raw = elapsed * (1 - progress) / progress
        let clamped = max(0, raw)
        // 指数平滑，进度初期波动大时更依赖新值
        let alpha = 0.3
        if let prev = estimatedRemainingSeconds {
            estimatedRemainingSeconds = prev * (1 - alpha) + clamped * alpha
        } else {
            estimatedRemainingSeconds = clamped
        }
    }

    /// 导入阶段读取时长与波形（在后台线程执行，避免阻塞主线程）
    private func loadDurationAndWaveform(url: URL) async throws -> (duration: TimeInterval, waveform: [Float]) {
        let duration = try await AudioFileService.getMediaDuration(url: url)
        let waveform: [Float] = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let audioData = try AudioFileService.loadAndResample(url: url)
                    let samples = AudioFileService.extractWaveformSamples(from: audioData)
                    continuation.resume(returning: samples)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return (duration, waveform)
    }

    /// 显示错误消息
    private func showErrorMessage(_ message: String) {
        errorMessage = message
        showError = true
    }
}
