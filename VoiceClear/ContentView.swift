//
//  ContentView.swift
//  VoiceClear
//
//  Created by jxing on 2026/2/12.
//

import SwiftUI

// MARK: - 功能模块定义

/// 应用的功能模块
enum FeatureItem: String, CaseIterable, Identifiable, Hashable {
    case denoisePlayer = "降噪播放"
    case fileConversion = "文件转换"

    var id: String { rawValue }

    /// 本地化后的功能名称（用于导航栏标题等）
    var localizedTitle: String {
        String(localized: String.LocalizationValue(stringLiteral: rawValue))
    }

    /// 本地化后的功能描述
    var localizedSubtitle: String {
        String(localized: String.LocalizationValue(stringLiteral: subtitleRaw))
    }

    /// 功能描述原始值（供本地化使用）
    private var subtitleRaw: String {
        switch self {
        case .denoisePlayer:  return "实时降噪 · 边播边听"
        case .fileConversion: return "批量降噪 · 导出文件"
        }
    }

    /// 功能图标
    var icon: String {
        switch self {
        case .denoisePlayer:  return "waveform.circle.fill"
        case .fileConversion: return "doc.on.doc.fill"
        }
    }

    /// 功能描述（已本地化）
    var subtitle: String { localizedSubtitle }

    /// 卡片渐变色
    var gradient: [Color] {
        switch self {
        case .denoisePlayer:  return [.blue, .cyan]
        case .fileConversion: return [.purple, .pink]
        }
    }
}

// MARK: - 主界面

struct ContentView: View {

    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            homeView
                .navigationDestination(for: FeatureItem.self) { item in
                    switch item {
                    case .denoisePlayer:
                        DenoisePlayerView()
                            .navigationTitle(item.localizedTitle)
                            #if os(macOS)
                            .navigationSubtitle(item.subtitle)
                            #endif
                    case .fileConversion:
                        FileConversionView()
                            .navigationTitle(item.localizedTitle)
                            #if os(macOS)
                            .navigationSubtitle(item.subtitle)
                            #endif
                    }
                }
        }
    }

    // MARK: - 首页

    private var homeView: some View {
        ScrollView {
            VStack(spacing: 32) {
                // 顶部 Logo & 标题
                appHeader
                    .padding(.top, 40)

                // 功能入口卡片
                featureCards
                    .padding(.horizontal, 24)

                // 底部版本信息
                footerInfo
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
        }
        .background(Color.platformBackground)
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - 顶部 Logo & 标题

    private var appHeader: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(
                    .linearGradient(
                        colors: [.blue, .cyan],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .symbolEffect(.pulse, options: .repeating.speed(0.5))

            Text("Voice Clear")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("AI 音频降噪工具")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 功能入口卡片

    private var featureCards: some View {
        VStack(spacing: 16) {
            ForEach(FeatureItem.allCases) { item in
                featureCard(item)
            }
        }
        .frame(maxWidth: 500)
    }

    private func featureCard(_ item: FeatureItem) -> some View {
        Button {
            path.append(item)
        } label: {
            HStack(spacing: 16) {
                // 图标区域
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(
                            .linearGradient(
                                colors: item.gradient,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 56, height: 56)

                    Image(systemName: item.icon)
                        .font(.title2)
                        .foregroundStyle(.white)
                }

                // 文字区域
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.localizedTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(item.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // 箭头
                Image(systemName: "chevron.right")
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底部信息

    private var footerInfo: some View {
        Text("版本 1.0 · 基于 RNNoise 引擎")
            .font(.caption)
            .foregroundStyle(.quaternary)
    }
}

#Preview {
    ContentView()
}
