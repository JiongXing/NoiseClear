//
//  AudioFileService.swift
//  VoiceClean
//
//  Created by jxing on 2026/2/12.
//

import AVFoundation
#if os(macOS)
import AppKit
#endif
import UniformTypeIdentifiers

// MARK: - 音频文件服务

/// 负责文件选择、音频/视频读取/写入、格式转换
///
/// - macOS: 文件选择通过 NSOpenPanel / NSSavePanel
/// - iOS: 文件选择交由 View 层的 `.fileImporter()` / `.fileExporter()` 驱动
enum AudioFileService {

    // MARK: - 常量

    /// 标准化输出采样率（与降噪输出保持一致）
    static let targetSampleRate: Double = 16000.0

    /// 波形可视化的采样点数量
    static let waveformSampleCount: Int = 200

    // MARK: - 文件选择（仅 macOS）

    #if os(macOS)
    /// 打开文件选择面板，让用户选择音频或视频文件
    @MainActor
    static func openFilePicker() async -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "选择音频或视频文件"
        panel.message = "选择一个或多个音频/视频文件进行降噪"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .mpeg4Movie, .quickTimeMovie]

        let response = panel.runModal()
        guard response == .OK else { return [] }
        return panel.urls
    }

    /// 打开保存面板，让用户选择导出位置
    @MainActor
    static func openSavePanel(
        suggestedName: String,
        allowedContentTypes: [UTType] = [.wav]
    ) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "导出降噪后的文件"
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = allowedContentTypes
        panel.canCreateDirectories = true

        let response = panel.runModal()
        guard response == .OK else { return nil }
        return panel.url
    }
    #endif

    // MARK: - 媒体信息读取

    /// 读取媒体文件时长（支持音频和视频）
    static func getMediaDuration(url: URL) throws -> TimeInterval {
        let ext = url.pathExtension.lowercased()

        if kVideoExtensions.contains(ext) {
            // 视频文件使用 AVURLAsset 获取时长
            let asset = AVURLAsset(url: url)
            let duration = CMTimeGetSeconds(asset.duration)
            guard duration.isFinite && duration > 0 else {
                throw AudioFileServiceError.invalidDuration
            }
            return duration
        } else {
            // 音频文件使用 AVAudioFile 获取时长
            let audioFile = try AVAudioFile(forReading: url)
            let sampleRate = audioFile.processingFormat.sampleRate
            let frameCount = Double(audioFile.length)
            return frameCount / sampleRate
        }
    }

    // MARK: - 音频读取

    /// 读取音频/视频文件并转换为 16kHz 单声道 Float32 PCM 数据
    ///
    /// 对于视频文件，会先通过 AVFoundation 提取音频轨道再加载。
    static func loadAndResample(url: URL) throws -> [Float] {
        let ext = url.pathExtension.lowercased()

        if kVideoExtensions.contains(ext) {
            // 视频文件：先用 AVFoundation 提取音频到临时 WAV，再加载
            let tempAudioURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("vc_extract_\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: tempAudioURL) }

            try extractAudioFromVideo(from: url, to: tempAudioURL)
            return try loadAndResampleAudioFile(url: tempAudioURL)
        } else {
            return try loadAndResampleAudioFile(url: url)
        }
    }

    /// 读取纯音频文件并转换为 16kHz 单声道 Float32 PCM 数据
    private static func loadAndResampleAudioFile(url: URL) throws -> [Float] {
        let sourceFile = try AVAudioFile(forReading: url)
        let sourceFormat = sourceFile.processingFormat

        // 目标格式：16kHz 单声道 Float32
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioFileServiceError.formatCreationFailed
        }

        // 读取源文件全部数据
        let sourceFrameCount = AVAudioFrameCount(sourceFile.length)
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: sourceFrameCount
        ) else {
            throw AudioFileServiceError.bufferCreationFailed
        }
        try sourceFile.read(into: sourceBuffer)

        // 如果已经是目标格式，直接返回
        if sourceFormat.sampleRate == targetSampleRate
            && sourceFormat.channelCount == 1
        {
            return bufferToFloatArray(sourceBuffer)
        }

        // 创建转换器
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioFileServiceError.converterCreationFailed
        }

        // 计算目标缓冲区大小
        let ratio = targetSampleRate / sourceFormat.sampleRate
        let targetFrameCount = AVAudioFrameCount(Double(sourceFrameCount) * ratio)
        guard let targetBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: targetFrameCount
        ) else {
            throw AudioFileServiceError.bufferCreationFailed
        }

        // 执行转换
        var isDone = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if isDone {
                outStatus.pointee = .noDataNow
                return nil
            }
            isDone = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        var error: NSError?
        converter.convert(to: targetBuffer, error: &error, withInputFrom: inputBlock)
        if let error {
            throw AudioFileServiceError.conversionFailed(error.localizedDescription)
        }

        return bufferToFloatArray(targetBuffer)
    }

    // MARK: - 视频音频提取

    /// 从视频文件中提取音频轨道为 16kHz 单声道 WAV
    ///
    /// 使用 AVAssetReader 解码音频轨道，输出为 16kHz 单声道 Float32 PCM WAV。
    ///
    /// - Parameters:
    ///   - videoURL: 视频文件 URL
    ///   - audioURL: 输出 WAV 文件 URL
    static func extractAudioFromVideo(from videoURL: URL, to audioURL: URL) throws {
        let asset = AVURLAsset(url: videoURL)
        guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
            throw AudioFileServiceError.audioExtractionFailed("视频文件中未找到音频轨道")
        }

        let reader = try AVAssetReader(asset: asset)

        let readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
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
            throw AudioFileServiceError.audioExtractionFailed(
                reader.error?.localizedDescription ?? "AVAssetReader 启动失败"
            )
        }

        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )!

        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let outputFile = try AVAudioFile(
            forWriting: audioURL,
            settings: fileSettings,
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

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw AudioFileServiceError.audioExtractionFailed("输出文件不存在")
        }
    }

    // MARK: - 便捷方法

    /// 从媒体文件 URL 直接加载并提取波形采样点（用于可视化）
    ///
    /// 支持音频和视频文件。对于视频文件会自动提取音频轨道。
    /// - Parameter url: 媒体文件 URL
    /// - Returns: 降采样后的波形 RMS 采样点数组
    static func loadWaveformFromFile(url: URL) throws -> [Float] {
        let audioData = try loadAndResample(url: url)
        return extractWaveformSamples(from: audioData)
    }

    /// 生成降噪输出文件的临时 URL
    /// - Parameters:
    ///   - originalFileName: 原始文件名
    ///   - isVideo: 是否为视频文件（视频保留原扩展名，音频输出 WAV）
    static func generateTempOutputURL(originalFileName: String, isVideo: Bool = false) -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let baseName = (originalFileName as NSString).deletingPathExtension

        let outputExtension: String
        if isVideo {
            // 视频文件保留原始容器格式
            let originalExt = (originalFileName as NSString).pathExtension.lowercased()
            outputExtension = originalExt.isEmpty ? "mp4" : originalExt
        } else {
            outputExtension = "wav"
        }

        let outputName = "\(baseName)_denoised.\(outputExtension)"
        let outputURL = tempDir.appendingPathComponent(outputName)

        // 如果文件已存在则删除
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        return outputURL
    }

    // MARK: - 波形数据提取

    /// 从音频数据中提取用于可视化的波形采样点
    static func extractWaveformSamples(from audioData: [Float], count: Int = waveformSampleCount) -> [Float] {
        guard !audioData.isEmpty else { return [] }

        let chunkSize = max(1, audioData.count / count)
        var samples: [Float] = []
        samples.reserveCapacity(count)

        for i in 0..<count {
            let start = i * chunkSize
            let end = min(start + chunkSize, audioData.count)
            guard start < audioData.count else { break }

            // 取每个 chunk 的 RMS 值
            let chunk = Array(audioData[start..<end])
            let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
            samples.append(rms)
        }

        return samples
    }

    // MARK: - 音频写入

    /// 将 Float32 PCM 数据写入 WAV 文件
    static func writeWAV(data: [Float], sampleRate: Double = targetSampleRate, to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioFileServiceError.formatCreationFailed
        }

        let frameCount = AVAudioFrameCount(data.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioFileServiceError.bufferCreationFailed
        }
        buffer.frameLength = frameCount

        // 拷贝数据到缓冲区
        if let channelData = buffer.floatChannelData?[0] {
            data.withUnsafeBufferPointer { src in
                channelData.update(from: src.baseAddress!, count: data.count)
            }
        }

        let outputFile = try AVAudioFile(forWriting: url, settings: format.settings)
        try outputFile.write(from: buffer)
    }

    /// 将处理后的音频保存到临时目录，返回临时文件 URL
    static func saveToTempFile(data: [Float], originalFileName: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let baseName = (originalFileName as NSString).deletingPathExtension
        let outputName = "\(baseName)_denoised.wav"
        let outputURL = tempDir.appendingPathComponent(outputName)

        // 如果文件已存在则删除
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        try writeWAV(data: data, to: outputURL)
        return outputURL
    }

    /// 将临时文件复制到用户选择的位置
    static func exportFile(from sourceURL: URL, to destinationURL: URL) throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    // MARK: - 私有辅助方法

    /// 将 AVAudioPCMBuffer 转换为 Float 数组
    private static func bufferToFloatArray(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameLength = Int(buffer.frameLength)

        if buffer.format.channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
        }

        // 多声道 -> 混合为单声道
        var mono = [Float](repeating: 0, count: frameLength)
        let channelCount = Int(buffer.format.channelCount)
        for ch in 0..<channelCount {
            let chData = channelData[ch]
            for i in 0..<frameLength {
                mono[i] += chData[i]
            }
        }
        let scale = 1.0 / Float(channelCount)
        for i in 0..<frameLength {
            mono[i] *= scale
        }
        return mono
    }
}

// MARK: - 错误类型

enum AudioFileServiceError: LocalizedError {
    case formatCreationFailed
    case bufferCreationFailed
    case converterCreationFailed
    case conversionFailed(String)
    case fileNotFound(String)
    case audioExtractionFailed(String)
    case invalidDuration

    var errorDescription: String? {
        switch self {
        case .formatCreationFailed:
            return "无法创建音频格式"
        case .bufferCreationFailed:
            return "无法创建音频缓冲区"
        case .converterCreationFailed:
            return "无法创建音频转换器"
        case .conversionFailed(let msg):
            return "音频转换失败: \(msg)"
        case .fileNotFound(let path):
            return "找不到文件: \(path)"
        case .audioExtractionFailed(let msg):
            return "从视频提取音频失败: \(msg)"
        case .invalidDuration:
            return "无法读取媒体文件时长"
        }
    }
}
