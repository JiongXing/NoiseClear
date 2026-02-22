//
//  RNNoiseProcessor.swift
//  VoiceClear
//
//  RNNoise 降噪处理器 — 原生 Swift 封装
//
//  基于 xiph/rnnoise C 库，提供帧级别 (frame-level) 的降噪 API。
//  RNNoise 固定以 480 采样点（48kHz 下 10ms）为一帧进行处理。
//
//  使用方式:
//    let processor = try RNNoiseProcessor()                 // 使用默认模型
//    let processor = try RNNoiseProcessor(modelPath: path)  // 使用自定义模型
//    let cleaned = processor.processFrame(inputFrame)       // 处理一帧
//    processor.close()                                       // 释放资源
//

import Foundation
import RNNoise

// MARK: - RNNoise 降噪处理器

/// 对 xiph/rnnoise C 库的 Swift 封装
///
/// 线程安全说明：单个 `RNNoiseProcessor` 实例不是线程安全的，
/// 需要在同一线程/队列上调用 `processFrame` 和 `close`。
final class RNNoiseProcessor {

    // MARK: - 常量

    /// RNNoise 固定帧大小（采样点数）
    /// 48kHz 下 = 10ms
    static let frameSize: Int = 480

    /// RNNoise 要求的采样率
    static let sampleRate: Double = 48000.0

    // MARK: - 私有属性

    /// RNNoise 降噪状态
    private var state: OpaquePointer?

    /// 自定义模型（如果有）
    private var model: OpaquePointer?

    // MARK: - 初始化

    /// 使用内置默认模型初始化
    ///
    /// 新版 xiph/rnnoise 使用编译进二进制的默认模型（rnnoise_data.c），
    /// 旧的 std.rnnn 外部模型文件已不再需要。
    convenience init() throws {
        try self.init(modelPath: nil)
    }

    /// 使用指定模型文件初始化
    ///
    /// - Parameter modelPath: 模型文件路径（.rnnn），nil 表示使用内置默认模型
    init(modelPath: String?) throws {
        if let modelPath {
            let loadedModel = rnnoise_model_from_filename(modelPath)
            guard loadedModel != nil else {
                throw RNNoiseError.modelLoadFailed(modelPath)
            }
            self.model = loadedModel
            self.state = rnnoise_create(loadedModel)
        } else {
            self.model = nil
            self.state = rnnoise_create(nil)
        }

        guard state != nil else {
            // 清理已加载的模型
            if let m = model { rnnoise_model_free(m) }
            throw RNNoiseError.createFailed
        }
    }

    deinit {
        close()
    }

    // MARK: - 降噪处理

    /// 处理一帧音频数据（原地降噪）
    ///
    /// - Parameter frame: 包含 `frameSize` (480) 个 Float32 采样点的数组
    /// - Returns: 降噪后的采样点数组，以及 VAD 概率 (0.0~1.0，表示是否为语音)
    func processFrame(_ frame: [Float]) -> (output: [Float], vadProbability: Float) {
        guard let state else {
            return (frame, 0)
        }

        var input = frame
        // 补齐或截断到 frameSize
        if input.count < Self.frameSize {
            input.append(contentsOf: [Float](repeating: 0, count: Self.frameSize - input.count))
        }

        var output = [Float](repeating: 0, count: Self.frameSize)
        let vad = rnnoise_process_frame(state, &output, &input)

        return (output, vad)
    }

    /// 处理一帧音频数据（UnsafeMutablePointer 版本，零拷贝）
    ///
    /// - Parameters:
    ///   - output: 输出缓冲区，至少 `frameSize` 个 Float32
    ///   - input: 输入缓冲区，至少 `frameSize` 个 Float32
    /// - Returns: VAD 概率
    @discardableResult
    func processFrame(output: UnsafeMutablePointer<Float>, input: UnsafePointer<Float>) -> Float {
        guard let state else { return 0 }
        return rnnoise_process_frame(state, output, input)
    }

    // MARK: - 资源释放

    /// 释放 RNNoise 资源
    func close() {
        if let s = state {
            rnnoise_destroy(s)
            state = nil
        }
        if let m = model {
            rnnoise_model_free(m)
            model = nil
        }
    }

    /// 是否已关闭
    var isClosed: Bool {
        state == nil
    }
}

// MARK: - RNNoise 批量处理辅助

extension RNNoiseProcessor {

    /// 处理完整的音频数据（自动分帧）
    ///
    /// 输入数据会被自动分成 480 采样点的帧进行处理。
    /// 最后不足一帧的部分会用零填充。
    ///
    /// - Parameters:
    ///   - samples: 输入音频数据（单声道 48kHz Float32）
    ///   - strength: 降噪强度 (0.0 ~ 1.0)，通过混合原始和降噪信号实现
    /// - Returns: 降噪后的完整音频数据
    func processAll(_ samples: [Float], strength: Float = 1.0) -> [Float] {
        let totalSamples = samples.count
        guard totalSamples > 0 else { return [] }

        let clampedStrength = max(0.0, min(1.0, strength))
        var output = [Float](repeating: 0, count: totalSamples)
        let frameSize = Self.frameSize

        var offset = 0
        while offset < totalSamples {
            let remaining = totalSamples - offset
            let currentFrameSize = min(frameSize, remaining)

            // 准备输入帧
            var inputFrame = [Float](repeating: 0, count: frameSize)
            for i in 0..<currentFrameSize {
                inputFrame[i] = samples[offset + i]
            }

            // 降噪
            var outputFrame = [Float](repeating: 0, count: frameSize)
            rnnoise_process_frame(state, &outputFrame, &inputFrame)

            // 混合原始和降噪信号
            for i in 0..<currentFrameSize {
                if clampedStrength >= 1.0 {
                    output[offset + i] = outputFrame[i]
                } else if clampedStrength <= 0.0 {
                    output[offset + i] = samples[offset + i]
                } else {
                    output[offset + i] = samples[offset + i] * (1.0 - clampedStrength) + outputFrame[i] * clampedStrength
                }
            }

            offset += frameSize
        }

        return output
    }
}

// MARK: - 错误类型

enum RNNoiseError: LocalizedError {
    case modelLoadFailed(String)
    case createFailed

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path):
            return "无法加载 RNNoise 模型文件: \(path)"
        case .createFailed:
            return "无法创建 RNNoise 降噪实例"
        }
    }
}
