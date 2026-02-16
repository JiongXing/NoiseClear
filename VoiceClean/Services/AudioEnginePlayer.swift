//
//  AudioEnginePlayer.swift
//  VoiceClean
//
//  Created by jxing on 2026/2/15.
//

import AVFoundation
import Foundation

// MARK: - 基于 AVAudioEngine 的音频播放器

/// 接收 AVAudioPCMBuffer 流并通过 AVAudioEngine 实时播放
///
/// 设计思路:
/// - 外部通过 `scheduleBuffer(_:)` 持续喂入 PCM 数据
/// - 内部使用 AVAudioPlayerNode 将 buffer 排入播放队列
/// - 支持 play/pause/stop 以及音量控制
/// - 通过 `scheduledFrames` 追踪已调度的总帧数来计算播放时间
final class AudioEnginePlayer {

    // MARK: - 属性

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    /// 音频格式（需在 setup 时设置）
    private var format: AVAudioFormat?

    /// 已调度的总帧数（用于计算播放时间）
    private var scheduledFrameCount: Int64 = 0

    /// 当前队列中待播放的帧数（用于限制预缓冲大小）
    private var pendingFrameCount: Int64 = 0

    /// 用于线程安全更新帧计数
    private let frameLock = NSLock()

    /// 是否已完成 setup
    private(set) var isSetUp: Bool = false

    /// 是否正在播放
    var isPlaying: Bool {
        playerNode.isPlaying
    }

    /// 音量 (0.0 ~ 1.0)
    var volume: Float {
        get { playerNode.volume }
        set { playerNode.volume = max(0, min(1, newValue)) }
    }

    /// 当前播放时间（秒）
    ///
    /// 基于 playerNode 的 lastRenderTime 精确计算；
    /// 如果无法获取（尚未开始播放），则回退到帧计数估算。
    var currentTime: TimeInterval {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              let _ = format
        else {
            // 回退：根据已调度帧数粗略估算
            guard let fmt = format, fmt.sampleRate > 0 else { return 0 }
            frameLock.lock()
            let frames = scheduledFrameCount
            frameLock.unlock()
            return Double(frames) / fmt.sampleRate
        }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    /// 当前缓冲队列的时长（秒）
    var bufferedDuration: TimeInterval {
        guard let fmt = format, fmt.sampleRate > 0 else { return 0 }
        frameLock.lock()
        let pending = pendingFrameCount
        frameLock.unlock()
        return max(0, Double(pending) / fmt.sampleRate)
    }

    // MARK: - 配置

    /// 配置音频引擎
    /// - Parameter format: 输入 PCM 数据的格式（需与 StreamingDenoiser 输出一致）
    func setup(format: AVAudioFormat) throws {
        self.format = format

        // 连接节点: playerNode → mainMixerNode → outputNode
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)

        try engine.start()
        isSetUp = true
    }

    // MARK: - Buffer 调度

    /// 将一个 PCM buffer 调度到播放队列
    ///
    /// buffer 会按顺序排队播放，不会覆盖之前的 buffer。
    /// 调用时不要求在主线程。
    func scheduleBuffer(_ buffer: AVAudioPCMBuffer) {
        let frameCount = Int64(buffer.frameLength)
        frameLock.lock()
        pendingFrameCount += frameCount
        frameLock.unlock()
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            guard let self else { return }
            self.frameLock.lock()
            self.scheduledFrameCount += frameCount
            self.pendingFrameCount = max(0, self.pendingFrameCount - frameCount)
            self.frameLock.unlock()
        }
    }

    // MARK: - 播放控制

    /// 开始播放
    func play() {
        guard isSetUp else { return }
        if !engine.isRunning {
            try? engine.start()
        }
        playerNode.play()
    }

    /// 暂停播放（保留队列中的 buffer）
    func pause() {
        playerNode.pause()
    }

    /// 停止播放并清空所有已调度的 buffer
    func stop() {
        playerNode.stop()

        if engine.isRunning {
            engine.stop()
        }

        // 重置状态
        frameLock.lock()
        scheduledFrameCount = 0
        pendingFrameCount = 0
        frameLock.unlock()

        // 断开并重新准备，以便下次 setup
        engine.detach(playerNode)
        isSetUp = false
        format = nil
    }
}
