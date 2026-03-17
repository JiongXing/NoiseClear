//
//  ContentView.swift
//  NoiseClear
//
//  Created by jxing on 2026/2/12.
//

import SwiftUI

// MARK: - 功能模块定义

/// 应用的功能模块
enum FeatureItem: String, CaseIterable, Identifiable, Hashable {
    case denoisePlayer
    case fileConversion

    var id: String { rawValue }

    var titleKey: L10nKey {
        switch self {
        case .denoisePlayer:  return .homeFeatureDenoisePlayerTitle
        case .fileConversion: return .homeFeatureFileConversionTitle
        }
    }

    /// 功能描述本地化键
    var subtitleKey: L10nKey {
        switch self {
        case .denoisePlayer:  return .homeFeatureDenoisePlayerSubtitle
        case .fileConversion: return .homeFeatureFileConversionSubtitle
        }
    }

    /// 功能图标
    var icon: String {
        switch self {
        case .denoisePlayer:  return "waveform.circle.fill"
        case .fileConversion: return "doc.on.doc.fill"
        }
    }

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
    @EnvironmentObject private var languageSettings: LanguageSettings

    @State private var path = NavigationPath()
    @State private var isSettingsPresented = false
    @State private var showLanguageToast = false
    @State private var languageToastText = ""

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .trailing) {
                homeView
                    .navigationDestination(for: FeatureItem.self) { item in
                        switch item {
                        case .denoisePlayer:
                            DenoisePlayerView()
                                .navigationTitle(L10n.string(item.titleKey, locale: languageSettings.currentLocale))
                                #if os(macOS)
                                .navigationSubtitle(L10n.string(item.subtitleKey, locale: languageSettings.currentLocale))
                                #endif
                        case .fileConversion:
                            FileConversionView()
                                .navigationTitle(L10n.string(item.titleKey, locale: languageSettings.currentLocale))
                                #if os(macOS)
                                .navigationSubtitle(L10n.string(item.subtitleKey, locale: languageSettings.currentLocale))
                                #endif
                        }
                    }
                    .toolbar {
                        #if os(macOS)
                        ToolbarItem(placement: .automatic) {
                            settingsButton
                        }
                        #else
                        ToolbarItem(placement: .topBarTrailing) {
                            settingsButton
                        }
                        #endif
                    }

                settingsMask
                    .opacity(isSettingsPresented ? 1 : 0)
                    .allowsHitTesting(isSettingsPresented)
                    .zIndex(1)

                drawerContainer
                    .zIndex(2)

                if showLanguageToast {
                    languageToast
                        .padding(.top, 12)
                        .zIndex(3)
                }
            }
            .environment(\.locale, languageSettings.currentLocale)
            #if os(macOS)
            .onExitCommand {
                guard isSettingsPresented else { return }
                isSettingsPresented = false
            }
            #endif
            .onChange(of: languageSettings.selectedLanguage) { _, newLanguage in
                let name = L10n.string(newLanguage.nameKey, locale: newLanguage.locale)
                languageToastText = L10n.string(.settingsLanguageSwitchedTo, locale: newLanguage.locale, name)
                withAnimation(.easeOut(duration: 0.2)) {
                    showLanguageToast = true
                }

                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.4))
                    withAnimation(.easeIn(duration: 0.2)) {
                        showLanguageToast = false
                    }
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

            Text(L10n.text(.homeAppName))
                .font(.largeTitle)
                .fontWeight(.bold)

            Text(L10n.text(.homeAppSubtitle))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 设置抽屉

    private var settingsButton: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                isSettingsPresented.toggle()
            }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
                .background {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay {
                            Circle()
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                        }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n.text(.homeSettingsAccessibility)))
    }

    private var settingsMask: some View {
        Rectangle()
            .fill(Color.black.opacity(0.18))
            .ignoresSafeArea()
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                    isSettingsPresented = false
                }
            }
    }

    private var drawerContainer: some View {
        GeometryReader { proxy in
            let width = drawerWidth(for: proxy.size.width)
            let hiddenOffset = width + 24

            SettingsDrawerView()
                .frame(width: width)
                .offset(x: isSettingsPresented ? 0 : hiddenOffset)
                .padding(.trailing, 12)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .allowsHitTesting(isSettingsPresented)
                .accessibilityHidden(!isSettingsPresented)
                .animation(.spring(response: 0.32, dampingFraction: 0.9), value: isSettingsPresented)
        }
    }

    private func drawerWidth(for containerWidth: CGFloat) -> CGFloat {
        #if os(macOS)
        min(max(340, containerWidth * 0.36), 440)
        #else
        min(max(280, containerWidth * 0.78), 360)
        #endif
    }

    private var languageToast: some View {
        Text(languageToastText)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background {
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                    }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .allowsHitTesting(false)
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
                    Text(L10n.text(item.titleKey))
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(L10n.text(item.subtitleKey))
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
        Text(L10n.text(.homeFooterVersion))
            .font(.caption)
            .foregroundStyle(.quaternary)
    }
}

#Preview {
    ContentView()
}
