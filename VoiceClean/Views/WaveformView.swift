//
//  WaveformView.swift
//  VoiceClean
//
//  Created by jxing on 2026/2/12.
//

import SwiftUI

// MARK: - 波形可视化视图

/// 显示音频波形的视图，支持平滑曲线和竖线条两种风格
/// 模仿 Logic Pro / Audacity 等专业音频软件的波形显示风格
struct WaveformView: View {

    /// 波形绘制风格
    enum Style {
        /// 平滑贝塞尔曲线包络 + 渐变填充
        case smooth
        /// 竖线条（bar），类似原始示波器风格
        case bars
    }

    /// 波形采样数据（RMS 值）
    let samples: [Float]

    /// 波形颜色
    var color: Color = .accentColor

    /// 绘制风格
    var style: Style = .bars

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
                    let halfH = size.height / 2 - 1

                    // 中心参考线
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

                    switch style {
                    case .bars:
                        Self.drawBars(
                            context: &context, size: size, samples: samples,
                            maxAmplitude: maxAmplitude, midY: midY, halfH: halfH,
                            mirrored: mirrored, color: color, lineWidth: lineWidth
                        )
                    case .smooth:
                        Self.drawSmooth(
                            context: &context, size: size, samples: samples,
                            maxAmplitude: maxAmplitude, midY: midY, halfH: halfH,
                            mirrored: mirrored, color: color, lineWidth: lineWidth
                        )
                    }
                }
            }
        }
    }

    // MARK: - Bar 风格绘制

    /// 竖线条风格：每个采样绘制一根从中线向上下延伸的竖线，视觉上类似示波器 / App 图标
    private static func drawBars(
        context: inout GraphicsContext,
        size: CGSize,
        samples: [Float],
        maxAmplitude: Float,
        midY: CGFloat,
        halfH: CGFloat,
        mirrored: Bool,
        color: Color,
        lineWidth: CGFloat
    ) {
        let count = samples.count
        let barWidth = max(lineWidth, size.width / CGFloat(count))
        let gap: CGFloat = max(0.5, barWidth * 0.15)
        let netBar = barWidth - gap

        let gradient = Gradient(colors: [
            color.opacity(0.95),
            color.opacity(0.35),
        ])

        for i in 0..<count {
            let x = CGFloat(i) * barWidth + gap / 2
            let n = linearToDbNormalized(samples[i], reference: maxAmplitude)
            let offset = max(0.5, n * halfH)

            let rect: CGRect
            if mirrored {
                rect = CGRect(x: x, y: midY - offset, width: netBar, height: offset * 2)
            } else {
                rect = CGRect(x: x, y: midY - offset, width: netBar, height: offset)
            }

            let barPath = Path(roundedRect: rect, cornerRadius: netBar * 0.25)

            context.fill(barPath, with: .linearGradient(
                gradient,
                startPoint: CGPoint(x: x, y: midY - offset),
                endPoint: CGPoint(x: x, y: midY + (mirrored ? offset : 0))
            ))
        }
    }

    // MARK: - Smooth 风格绘制

    /// 平滑贝塞尔曲线包络 + 渐变填充
    private static func drawSmooth(
        context: inout GraphicsContext,
        size: CGSize,
        samples: [Float],
        maxAmplitude: Float,
        midY: CGFloat,
        halfH: CGFloat,
        mirrored: Bool,
        color: Color,
        lineWidth: CGFloat
    ) {
        let count = samples.count
        let stepX = size.width / CGFloat(count - 1)

        var upperPoints = [CGPoint]()
        var lowerPoints = [CGPoint]()
        upperPoints.reserveCapacity(count)
        lowerPoints.reserveCapacity(count)

        for i in 0..<count {
            let x = CGFloat(i) * stepX
            let n = linearToDbNormalized(samples[i], reference: maxAmplitude)
            let offset = n * halfH
            upperPoints.append(CGPoint(x: x, y: midY - offset))
            lowerPoints.append(CGPoint(x: x, y: midY + offset))
        }

        var fillPath = Path()
        addSmoothCurve(to: &fillPath, through: upperPoints)
        if mirrored {
            appendSmoothCurve(to: &fillPath, through: lowerPoints.reversed())
        } else {
            fillPath.addLine(to: CGPoint(x: upperPoints.last!.x, y: size.height))
            fillPath.addLine(to: CGPoint(x: 0, y: size.height))
        }
        fillPath.closeSubpath()

        let gradient = Gradient(colors: [
            color.opacity(0.45),
            color.opacity(0.12),
        ])
        if mirrored {
            context.fill(fillPath, with: .linearGradient(
                gradient,
                startPoint: CGPoint(x: 0, y: midY - halfH),
                endPoint: CGPoint(x: 0, y: midY)
            ))
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

        var upperStroke = Path()
        addSmoothCurve(to: &upperStroke, through: upperPoints)
        context.stroke(
            upperStroke,
            with: .color(color.opacity(0.95)),
            lineWidth: lineWidth
        )

        if mirrored {
            var lowerStroke = Path()
            addSmoothCurve(to: &lowerStroke, through: lowerPoints)
            context.stroke(
                lowerStroke,
                with: .color(color.opacity(0.95)),
                lineWidth: lineWidth
            )
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
