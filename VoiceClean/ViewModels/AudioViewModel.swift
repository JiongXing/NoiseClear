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

    // MARK: - iOS 文件选择状态（由 View 层的 .fileImporter/.fileExporter 消费）

    #if os(iOS)
    /// 是否展示文件选择器（由 View 层 .fileImporter 绑定）
    var showFilePicker: Bool = false

    /// 是否展示保存面板（由 View 层 .fileExporter 绑定）
    var showSavePanel: Bool = false

    /// 待导出的文件（用于 .fileExporter）
    var pendingExportFile: AudioFileItem?
    #endif

    // MARK: - 计算属性

    /// 是否有文件可以处理
    var hasFilesToProcess: Bool {
        audioFiles.contains { $0.status == .idle || $0.status.displayText.hasPrefix("失败") }
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
                showErrorMessage("无法读取文件 \(url.lastPathComponent): \(error.localizedDescription)")
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
            guard audioFiles[i].status == .idle
                || audioFiles[i].status.displayText.hasPrefix("失败")
            else { continue }

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
            showErrorMessage("导出失败: \(error.localizedDescription)")
        }
        #else
        pendingExportFile = item
        showSavePanel = true
        #endif
    }

    #if os(iOS)
    /// iOS: 将文件导出到用户选择的位置
    func exportFileToURL(_ item: AudioFileItem, destination: URL) {
        guard case .completed(let tempURL) = item.status else { return }
        do {
            try AudioFileService.exportFile(from: tempURL, to: destination)
        } catch {
            showErrorMessage("导出失败: \(error.localizedDescription)")
        }
    }
    #endif

    /// 导出所有已完成的文件
    func exportAll() async {
        for item in audioFiles where item.status.isCompleted {
            await exportFile(item)
        }
    }

    // MARK: - 私有方法

    /// 处理指定索引的文件（使用 FFmpeg arnndn 降噪）
    ///
    /// 音频文件：直接降噪输出 WAV
    /// 视频文件：复制视频流 + 降噪音频轨道，输出原格式（MP4/MOV）
    private func processFile(at index: Int) async {
        guard index < audioFiles.count else { return }

        audioFiles[index].status = .processing(0)

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
                        // 初始化 FFmpeg 降噪引擎
                        let denoiser = try FFmpegDenoiser(strength: strength)

                        // 执行 FFmpeg 降噪（根据文件类型选择不同处理策略）
                        try denoiser.process(
                            inputURL: inputURL,
                            outputURL: outputURL,
                            duration: duration,
                            isVideo: isVideo
                        ) { progress in
                            DispatchQueue.main.async {
                                self.audioFiles[fileIndex].status = .processing(progress)
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

        } catch {
            guard index < audioFiles.count else { return }
            audioFiles[index].status = .failed(error.localizedDescription)
            showErrorMessage("处理 \(audioFiles[index].fileName) 失败: \(error.localizedDescription)")
        }
    }

    /// 显示错误消息
    private func showErrorMessage(_ message: String) {
        errorMessage = message
        showError = true
    }
}
