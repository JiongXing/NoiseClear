//
//  AudioViewModel.swift
//  VoiceClean
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
        for url in urls {
            // 避免重复添加
            guard !audioFiles.contains(where: { $0.url == url }) else { continue }

            // 检查文件扩展名（支持音频和视频）
            let ext = url.pathExtension.lowercased()
            guard kAllSupportedExtensions.contains(ext) else { continue }

            // iOS fileImporter 返回的 URL 是安全作用域资源，必须先获取访问权限
            let securityScoped = url.startAccessingSecurityScopedResource()
            defer { if securityScoped { url.stopAccessingSecurityScopedResource() } }

            do {
                let duration = try AudioFileService.getMediaDuration(url: url)

                // 预加载波形数据
                let audioData = try AudioFileService.loadAndResample(url: url)
                let waveform = AudioFileService.extractWaveformSamples(from: audioData)

                let item = AudioFileItem(
                    url: url,
                    duration: duration,
                    waveformSamples: waveform
                )
                audioFiles.append(item)
            } catch {
                showErrorMessage(String(format: String(localized: "Cannot read file %@: %@"), url.lastPathComponent, error.localizedDescription))
            }
        }
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
        audioFiles.removeAll()
        selectedFileID = nil
    }

    // MARK: - 降噪处理

    /// 处理所有待处理的文件
    func processAll() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        for i in audioFiles.indices {
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
        guard !isProcessing else { return }

        isProcessing = true
        defer { isProcessing = false }

        await processFile(at: index)
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
            showErrorMessage(String(format: String(localized: "Export failed: %@"), error.localizedDescription))
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

        audioFiles[index].status = .processing(0)
        processingStartTime = Date()
        estimatedRemainingSeconds = nil

        let inputURL = audioFiles[index].url
        let fileName = audioFiles[index].fileName
        let duration = audioFiles[index].duration
        let isVideo = audioFiles[index].isVideo
        let strength = Float(denoiseStrength)
        let fileIndex = index

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
            let result: (waveform: [Float], tempURL: URL) = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        // 初始化降噪引擎
                        let denoiser = FFmpegDenoiser(strength: strength)

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

        } catch {
            guard index < audioFiles.count else { return }
            audioFiles[index].status = .failed(error.localizedDescription)
            processingStartTime = nil
            estimatedRemainingSeconds = nil
            showErrorMessage(String(format: String(localized: "Processing %@ failed: %@"), audioFiles[index].fileName, error.localizedDescription))
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

    /// 显示错误消息
    private func showErrorMessage(_ message: String) {
        errorMessage = message
        showError = true
    }
}
