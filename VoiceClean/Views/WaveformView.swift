//
//  WaveformView.swift
//  VoiceClean
//
//  Created by jxing on 2026/2/12.
//

import SwiftUI

// MARK: - 波形可视化视图

/// 显示音频波形的视图，使用平滑折线包络 + 渐变填充
/// 模仿 Logic Pro / Audacity 等专业音频软件的波形显示风格
struct WaveformView: View {

    /// 波形采样数据（RMS 值）
    let samples: [Float]

    /// 波形颜色
    var color: Color = .accentColor

    /// 包络线条宽度
    var lineWidth: CGFloat = 1.2

    /// 是否镜像显示（上下对称包络）
    var mirrored: Bool = true

    /// 参考最大振幅（对比模式下统一归一化基准）
    /// 为 nil 时使用自身最大值
    var referenceMaxAmplitude: Float? = nil

    /// 是否绘制中心参考线
    var showCenterLine: Bool = true

    // MARK: - dB 对数刻度

    /// dB 动态范围下限（低于此值视为静音）
    private static let dbFloor: Float = -60.0

    /// 将线性 RMS 值转换为 0~1 的 dB 归一化值
    private static func linearToDbNormalized(_ value: Float, reference: Float) -> CGFloat {
        guard value > 0, reference > 0 else { return 0 }
        let db = 20.0 * log10(value / reference)
        let normalized = (db - dbFloor) / (0 - dbFloor)
        return CGFloat(max(0, min(1, normalized)))
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let midY = height / 2

            if samples.isEmpty {
                // 空状态：一条中间参考线
                Path { path in
                    path.move(to: CGPoint(x: 0, y: midY))
                    path.addLine(to: CGPoint(x: width, y: midY))
                }
                .stroke(color.opacity(0.3), lineWidth: 0.5)
            } else {
                Canvas { context, size in
                    let count = samples.count
                    guard count > 1 else { return }

                    let maxAmplitude = referenceMaxAmplitude ?? (samples.max() ?? 1.0)
                    let stepX = size.width / CGFloat(count - 1)
                    let halfH = size.height / 2 - 1

                    // 1. 计算上下包络点
                    var upperPoints = [CGPoint]()
                    var lowerPoints = [CGPoint]()
                    upperPoints.reserveCapacity(count)
                    lowerPoints.reserveCapacity(count)

                    for i in 0..<count {
                        let x = CGFloat(i) * stepX
                        let n = Self.linearToDbNormalized(samples[i], reference: maxAmplitude)
                        let offset = n * halfH
                        upperPoints.append(CGPoint(x: x, y: midY - offset))
                        lowerPoints.append(CGPoint(x: x, y: midY + offset))
                    }

                    // 2. 构建填充区域（上包络 → 下包络 → 闭合）
                    var fillPath = Path()
                    Self.addSmoothCurve(to: &fillPath, through: upperPoints)
                    if mirrored {
                        Self.appendSmoothCurve(to: &fillPath, through: lowerPoints.reversed())
                    } else {
                        // 非镜像模式：填充到底部
                        fillPath.addLine(to: CGPoint(x: upperPoints.last!.x, y: size.height))
                        fillPath.addLine(to: CGPoint(x: 0, y: size.height))
                    }
                    fillPath.closeSubpath()

                    // 3. 渐变填充（较高不透明度，增强视觉效果）
                    let gradient = Gradient(colors: [
                        color.opacity(0.45),
                        color.opacity(0.12),
                    ])
                    if mirrored {
                        // 从上下边缘向中心线渐变（对称）
                        context.fill(fillPath, with: .linearGradient(
                            gradient,
                            startPoint: CGPoint(x: 0, y: midY - halfH),
                            endPoint: CGPoint(x: 0, y: midY)
                        ))
                        // 下半部分镜像渐变
                        context.fill(fillPath, with: .linearGradient(
                            gradient,
                            startPoint: CGPoint(x: 0, y: midY + halfH),
                            endPoint: CGPoint(x: 0, y: midY)
                        ))
                    } else {
                        context.fill(fillPath, with: .linearGradient(
                            gradient,
                            startPoint: CGPoint(x: 0, y: 0),
                            endPoint: CGPoint(x: 0, y: size.height)
                        ))
                    }

                    // 4. 描边上包络线（高不透明度，清晰边缘）
                    var upperStroke = Path()
                    Self.addSmoothCurve(to: &upperStroke, through: upperPoints)
                    context.stroke(
                        upperStroke,
                        with: .color(color.opacity(0.95)),
                        lineWidth: lineWidth
                    )

                    // 5. 描边下包络线（镜像模式）
                    if mirrored {
                        var lowerStroke = Path()
                        Self.addSmoothCurve(to: &lowerStroke, through: lowerPoints)
                        context.stroke(
                            lowerStroke,
                            with: .color(color.opacity(0.95)),
                            lineWidth: lineWidth
                        )
                    }

                    // 6. 中心参考线
                    if showCenterLine {
                        var center = Path()
                        center.move(to: CGPoint(x: 0, y: midY))
                        center.addLine(to: CGPoint(x: size.width, y: midY))
                        context.stroke(
                            center,
                            with: .color(color.opacity(0.12)),
                            lineWidth: 0.5
                        )
                    }
                }
            }
        }
    }

    // MARK: - 平滑曲线构建

    /// 通过给定点集创建平滑二次贝塞尔曲线路径（新建子路径）
    private static func addSmoothCurve(to path: inout Path, through points: [CGPoint]) {
        guard let first = points.first else { return }
        path.move(to: first)
        guard points.count > 1 else { return }
        appendCurveSegments(to: &path, through: points)
    }

    /// 在已有路径上续接平滑曲线（不 move，直接续线）
    private static func appendSmoothCurve(to path: inout Path, through points: [CGPoint]) {
        guard let first = points.first else { return }
        path.addLine(to: first)
        guard points.count > 1 else { return }
        appendCurveSegments(to: &path, through: points)
    }

    /// 共享实现：用二次贝塞尔曲线平滑连接各点
    /// 使用"中点平滑"算法 — 以相邻点的中点为曲线端点，以数据点为控制点
    private static func appendCurveSegments(to path: inout Path, through points: [CGPoint]) {
        guard points.count > 2 else {
            if points.count == 2 {
                path.addLine(to: points[1])
            }
            return
        }

        // 首段：直线到第一个中点
        path.addLine(to: mid(points[0], points[1]))

        // 中间段：二次贝塞尔曲线，数据点为控制点，中点为端点
        for i in 1..<points.count - 1 {
            path.addQuadCurve(
                to: mid(points[i], points[i + 1]),
                control: points[i]
            )
        }

        // 尾段：直线到最后一个点
        path.addLine(to: points[points.count - 1])
    }

    /// 两点的中点
    private static func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) * 0.5, y: (a.y + b.y) * 0.5)
    }
}

// MARK: - 波形对比视图

/// 将原始和降噪后的波形上下分离显示，强化视觉对比
///
/// 设计原则：
/// - 上下分离布局（非叠加），让振幅差异一目了然
/// - 统一归一化基准，确保两行在同一刻度下可比
/// - 使用对比色（橙色 vs 绿色）区分原始与降噪后
/// - 镜像包络模式增大可视面积
/// - 右侧显示降噪率数值指标
struct WaveformComparisonView: View {

    let originalSamples: [Float]
    let processedSamples: [Float]

    /// 原始波形颜色（暖色调，代表"未处理"）
    private let originalColor = Color.orange
    /// 降噪波形颜色（冷色调/绿色，代表"已清理"）
    private let processedColor = Color.green

    /// 统一归一化基准：以原始波形的最大振幅为参考
    private var referenceMax: Float {
        originalSamples.max() ?? 1.0
    }

    /// 是否已有降噪结果
    private var hasProcessedData: Bool {
        !processedSamples.isEmpty
    }

    /// 降噪率（RMS 能量缩减百分比）
    private var reductionPercent: Int {
        guard hasProcessedData,
              !originalSamples.isEmpty,
              !processedSamples.isEmpty
        else { return 0 }

        let originalRMS = sqrt(originalSamples.reduce(0) { $0 + $1 * $1 } / Float(originalSamples.count))
        let processedRMS = sqrt(processedSamples.reduce(0) { $0 + $1 * $1 } / Float(processedSamples.count))
        guard originalRMS > 0 else { return 0 }

        let ratio = 1.0 - processedRMS / originalRMS
        return max(0, min(100, Int(ratio * 100)))
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── 上方：原始波形 ──
            waveformRow(
                label: "原始音频",
                icon: "waveform",
                samples: originalSamples,
                color: originalColor,
                trailingContent: { EmptyView() }
            )

            // 分隔线
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
                .padding(.horizontal, 4)

            // ── 下方：降噪后波形 ──
            waveformRow(
                label: hasProcessedData ? "降噪后" : "降噪后（待处理）",
                icon: "waveform.path.ecg",
                samples: hasProcessedData ? processedSamples : [],
                color: hasProcessedData ? processedColor : .secondary.opacity(0.3),
                trailingContent: {
                    // 降噪率指标
                    if hasProcessedData {
                        reductionBadge
                    }
                }
            )
        }
    }

    // MARK: - 单行波形

    /// 一行波形：标签 + 波形 + 可选右侧内容
    @ViewBuilder
    private func waveformRow<Trailing: View>(
        label: String,
        icon: String,
        samples: [Float],
        color: Color,
        @ViewBuilder trailingContent: () -> Trailing
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                // 左侧标签
                HStack(spacing: 3) {
                    Circle()
                        .fill(color.opacity(0.8))
                        .frame(width: 6, height: 6)

                    Text(label)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                trailingContent()
            }
            .padding(.horizontal, 4)

            // 波形
            WaveformView(
                samples: samples,
                color: color,
                lineWidth: 1.4,
                mirrored: true,
                referenceMaxAmplitude: referenceMax,
                showCenterLine: true
            )
            .frame(height: 52)
        }
        .padding(.vertical, 6)
    }

    // MARK: - 降噪率徽章

    private var reductionBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.down.right")
                .font(.system(size: 8, weight: .bold))
            Text("\(reductionPercent)%")
                .font(.caption2.monospacedDigit())
                .fontWeight(.semibold)
        }
        .foregroundStyle(processedColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background {
            Capsule()
                .fill(processedColor.opacity(0.12))
        }
    }
}

// MARK: - 预览

#Preview {
    let sampleData: [Float] = (0..<200).map { _ in Float.random(in: 0.05...1.0) }
    let processedData: [Float] = sampleData.map { max(0.02, $0 * 0.4) }

    return VStack(spacing: 24) {
        // 单独波形
        WaveformView(samples: sampleData, color: .blue)
            .frame(height: 80)

        Divider()

        // 对比视图
        WaveformComparisonView(
            originalSamples: sampleData,
            processedSamples: processedData
        )
    }
    .padding()
    .frame(width: 500)
}
