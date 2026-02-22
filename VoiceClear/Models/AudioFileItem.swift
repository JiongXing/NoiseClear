//
//  AudioFileItem.swift
//  VoiceClear
//
//  Created by jxing on 2026/2/12.
//

import Foundation
import UniformTypeIdentifiers
#if os(iOS)
import CoreTransferable
import PhotosUI
#endif

// MARK: - 处理状态

/// 音频文件的降噪处理状态
enum ProcessingStatus: Equatable {
    /// 空闲，等待处理
    case idle
    /// 正在处理，附带进度 (0.0 ~ 1.0)
    case processing(Double)
    /// 处理完成，附带输出文件的临时 URL
    case completed(URL)
    /// 处理失败，附带错误描述
    case failed(String)

    static func == (lhs: ProcessingStatus, rhs: ProcessingStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            return true
        case (.processing(let a), .processing(let b)):
            return a == b
        case (.completed(let a), .completed(let b)):
            return a == b
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }

    /// 当前进度值（仅在 .processing 状态时有意义）
    var progress: Double {
        if case .processing(let p) = self { return p }
        return 0
    }

    /// 是否处理完成
    var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }

    /// 是否正在处理
    var isProcessing: Bool {
        if case .processing = self { return true }
        return false
    }

    /// 输出文件 URL（仅在 .completed 状态时有值）
    var outputURL: URL? {
        if case .completed(let url) = self { return url }
        return nil
    }

    /// 状态的显示文本（已本地化）
    var displayText: String {
        switch self {
        case .idle:
            return String(localized: "等待处理")
        case .processing(let p):
            return String(format: String(localized: "处理中 %lld%%"), Int(p * 100))
        case .completed:
            return String(localized: "已完成")
        case .failed(let msg):
            return String(format: String(localized: "失败: %@"), msg)
        }
    }
}

// MARK: - 支持的文件类型

/// 支持的音频文件扩展名
let kAudioExtensions = ["mp3", "m4a", "wav", "aac", "aiff", "flac"]

/// 支持的视频文件扩展名
let kVideoExtensions = ["mp4", "mov"]

/// 所有支持的文件扩展名
let kAllSupportedExtensions = kAudioExtensions + kVideoExtensions

// MARK: - 音频/视频文件数据模型

/// 表示一个待处理的媒体文件（音频或视频）
struct AudioFileItem: Identifiable {
    let id: UUID
    let url: URL
    let fileName: String
    let duration: TimeInterval
    /// 原始音频波形采样点（用于可视化，已降采样）
    var waveformSamples: [Float]
    /// 处理后的波形采样点
    var processedWaveformSamples: [Float]
    /// 处理状态
    var status: ProcessingStatus

    init(url: URL, duration: TimeInterval, waveformSamples: [Float] = []) {
        self.id = UUID()
        self.url = url
        self.fileName = url.lastPathComponent
        self.duration = duration
        self.waveformSamples = waveformSamples
        self.processedWaveformSamples = []
        self.status = .idle
    }

    /// 文件扩展名（小写）
    var fileExtension: String {
        url.pathExtension.lowercased()
    }

    /// 是否为视频文件
    var isVideo: Bool {
        kVideoExtensions.contains(fileExtension)
    }

    /// 格式化时长显示（HH:MM:SS）
    var formattedDuration: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - 相册视频 Transferable 类型

#if os(iOS)
/// 用于从相册导入视频文件的 Transferable 包装
///
/// 使用 `FileRepresentation` 确保大视频直接流式写入磁盘临时文件，
/// 而非将整个视频加载到内存，避免内存暴涨导致进程被系统终止。
struct TransferableMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mp4" : received.file.pathExtension
            let fileName = "vc_album_\(UUID().uuidString).\(ext)"
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: received.file, to: dest)
            return Self(url: dest)
        }
    }
}
#endif
