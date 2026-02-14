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

                    // 3. 渐变填充
                    let gradient = Gradient(colors: [
                        color.opacity(0.30),
                        color.opacity(0.08),
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

                    // 4. 描边上包络线
                    var upperStroke = Path()
                    Self.addSmoothCurve(to: &upperStroke, through: upperPoints)
                    context.stroke(
                        upperStroke,
                        with: .color(color.opacity(0.85)),
                        lineWidth: lineWidth
                    )

                    // 5. 描边下包络线（镜像模式）
                    if mirrored {
                        var lowerStroke = Path()
                        Self.addSmoothCurve(to: &lowerStroke, through: lowerPoints)
                        context.stroke(
                            lowerStroke,
                            with: .color(color.opacity(0.85)),
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

/// 将原始和降噪后的波形叠加显示在同一坐标系中
/// 原始波形为灰色区域，降噪后波形为强调色叠加，差异一目了然
struct WaveformComparisonView: View {

    let originalSamples: [Float]
    let processedSamples: [Float]

    /// 统一归一化基准：以原始波形的最大振幅为参考
    private var referenceMax: Float {
        originalSamples.max() ?? 1.0
    }

    /// 是否已有降噪结果
    private var hasProcessedData: Bool {
        !processedSamples.isEmpty
    }

    var body: some View {
        VStack(spacing: 6) {
            // 图例
            HStack(spacing: 16) {
                legendItem(
                    color: .secondary,
                    text: "原始音频",
                    icon: "waveform"
                )

                legendItem(
                    color: hasProcessedData ? .accentColor : .secondary.opacity(0.4),
                    text: hasProcessedData ? "降噪后" : "降噪后（待处理）",
                    icon: "waveform.path.ecg"
                )

                Spacer()
            }

            // 叠加波形（单根折线 — RMS 能量包络模式）
            ZStack {
                // 底层：原始波形（灰色）
                WaveformView(
                    samples: originalSamples,
                    color: .secondary,
                    lineWidth: 1.0,
                    mirrored: false,
                    referenceMaxAmplitude: referenceMax,
                    showCenterLine: false
                )

                // 顶层：降噪后波形（强调色）
                if hasProcessedData {
                    WaveformView(
                        samples: processedSamples,
                        color: .accentColor,
                        lineWidth: 1.2,
                        mirrored: false,
                        referenceMaxAmplitude: referenceMax,
                        showCenterLine: false
                    )
                }
            }
            .frame(height: 60)
        }
    }

    /// 图例项
    private func legendItem(color: Color, text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color.opacity(0.6))
                .frame(width: 12, height: 4)

            Label(text, systemImage: icon)
                .font(.caption)
                .foregroundStyle(color)
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
