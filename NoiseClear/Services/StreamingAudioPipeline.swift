//
//  StreamingAudioPipeline.swift
//  NoiseClear
//
//  Unified pipeline interface for streaming playback.
//

import AVFoundation
import Foundation

/// 统一抽象“可持续产出 PCM Buffer”的播放管线。
///
/// `PlayerViewModel` 只依赖该协议，具体实现可在旧版分段实现与新版增量实现之间切换。
protocol StreamingAudioPipeline: AnyObject, Sendable {
    var isRunning: Bool { get }
    var playbackFormat: AVAudioFormat { get }
    func start(
        inputURL: URL,
        strength: Float,
        startTime: TimeInterval,
        maxDuration: TimeInterval?,
        isVideo: Bool
    ) throws
    func startOriginal(
        inputURL: URL,
        startTime: TimeInterval,
        maxDuration: TimeInterval?,
        isVideo: Bool
    ) throws
    func readNextBuffer() -> AVAudioPCMBuffer?
    func stop()
}

/// 流式管线模式：用于灰度和回退。
enum StreamingPipelineMode: String {
    case incrementalAVFoundation
    case legacyChunked
}

