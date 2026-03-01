//
//  DenoisePlayerView.swift
//  VoiceClear
//
//  Created by jxing on 2026/2/15.
//

import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
import UIKit
#endif

// MARK: - 降噪播放页面

/// 实时降噪播放功能：边播放边降噪，支持音频和视频文件
struct DenoisePlayerView: View {
    @EnvironmentObject private var languageSettings: LanguageSettings

    @State private var viewModel = PlayerViewModel()

    /// 是否正在拖拽进度条
    @State private var isSeeking = false

    /// 拖拽中的进度值
    @State private var seekProgress: Double = 0

    #if os(iOS)
    /// 是否显示文件来源选择对话框
    @State private var showSourceDialog = false

    /// 相册选择器选中的项目
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 媒体展示区域
                mediaDisplayArea

                // 播放控制条
                if shouldShowLoadedPanels {
                    playerControlsSection
                }

                if shouldShowLoadedPanels {
                    streamStatusSection
                }

                // 降噪 & 音量控制
                if shouldShowLoadedPanels {
                    settingsSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            #if os(iOS)
            .contentShape(Rectangle())
            .onTapGesture {
                dismissKeyboard()
            }
            #endif
        }
        #if os(iOS)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                dismissKeyboard()
            }
        )
        #endif
        .background(Color.platformBackground)
        .toolbar {
            if shouldShowLoadedPanels {
                ToolbarItem(placement: .automatic) {
                    HStack(spacing: 8) {
                        Image(systemName: viewModel.isVideo ? "film" : "music.note")
                            .foregroundStyle(.secondary)

                        Text(viewModel.fileName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        #if os(iOS)
        .fileImporter(
            isPresented: $viewModel.showFilePicker,
            allowedContentTypes: [.audio, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task { await viewModel.loadFile(url: url) }
                }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
                viewModel.showError = true
            }
        }
        .confirmationDialog(L10n.string(.playerSelectFileSource, locale: languageSettings.currentLocale), isPresented: $showSourceDialog) {
            Button(L10n.string(.playerSourceFromFiles, locale: languageSettings.currentLocale)) {
                viewModel.showFilePicker = true
            }
            Button(L10n.string(.playerSourceFromPhotos, locale: languageSettings.currentLocale)) {
                viewModel.showPhotoPicker = true
            }
            Button(L10n.string(.commonCancel, locale: languageSettings.currentLocale), role: .cancel) {}
        }
        .photosPicker(
            isPresented: $viewModel.showPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: 1,
            matching: .videos
        )
        .onChange(of: selectedPhotoItems) { _, newItems in
            guard let item = newItems.first else { return }
            Task {
                viewModel.isImporting = true
                defer { viewModel.isImporting = false }
                do {
                    if let movie = try await item.loadTransferable(type: TransferableMovie.self) {
                        await viewModel.loadFile(url: movie.url)
                    } else {
                        viewModel.errorMessage = L10n.string(.playerErrorCannotReadSelectedVideo, locale: languageSettings.currentLocale)
                        viewModel.showError = true
                    }
                } catch {
                    viewModel.errorMessage = L10n.string(.playerErrorImportAlbumFailed, locale: languageSettings.currentLocale, error.localizedDescription)
                    viewModel.showError = true
                }
                selectedPhotoItems = []
            }
        }
        .overlay {
            if viewModel.isImporting {
                importingOverlay
            }
        }
        #endif
        .alert(L10n.string(.commonError, locale: languageSettings.currentLocale), isPresented: $viewModel.showError) {
            Button(L10n.string(.commonConfirm, locale: languageSettings.currentLocale), role: .cancel) {}
        } message: {
            if let msg = viewModel.errorMessage {
                Text(msg)
            }
        }
        .onDisappear {
            // 离开页面时确保停止播放，避免后台继续出声。
            viewModel.stop()
        }
    }

    // MARK: - 媒体展示区域

    @ViewBuilder
    private var mediaDisplayArea: some View {
        if viewModel.isDownloading {
            remoteLoadingArea
        } else if let _ = viewModel.currentFile {
            // 已加载文件
            if viewModel.isVideo, let player = viewModel.avPlayer {
                // 视频文件：显示视频画面
                VideoPlayerView(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                    }
                    .frame(minHeight: 200, maxHeight: 400)
            } else {
                // 音频文件：显示音频可视化占位
                audioVisualArea
            }
        } else {
            // 未加载文件：显示拖拽区域 + URL 输入
            VStack(spacing: 16) {
                DropZoneView(
                    onDrop: { urls in
                        if let url = urls.first {
                            Task { await viewModel.loadFile(url: url) }
                        }
                    },
                    onTap: {
                        #if os(macOS)
                        Task { await viewModel.selectFile() }
                        #else
                        showSourceDialog = true
                        #endif
                    }
                )

                // 分隔线 "或"
                HStack(spacing: 12) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.1))
                        .frame(height: 1)

                    Text(L10n.text(.commonOr))
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Rectangle()
                        .fill(Color.primary.opacity(0.1))
                        .frame(height: 1)
                }
                .padding(.horizontal, 4)

                // 在线 URL 输入区域
                urlInputSection
            }
        }
    }

    /// 音频文件的可视化展示区域
    private var audioVisualArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }

            VStack(spacing: 16) {
                // 大图标
                Image(systemName: viewModel.isPlaying ? "waveform" : "music.note")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(viewModel.isPlaying ? Color.accentColor : .secondary)
                    .symbolEffect(.variableColor.iterative, isActive: viewModel.isPlaying)

                VStack(spacing: 4) {
                    Text(viewModel.fileName)
                        .font(.headline)
                        .lineLimit(1)

                    Text(L10n.text(playbackStateKey))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // 更换文件按钮
                if !viewModel.isPlaying {
                    Button {
                        #if os(macOS)
                        Task { await viewModel.selectFile() }
                        #else
                        showSourceDialog = true
                        #endif
                    } label: {
                        Label(L10n.string(.playerActionReplaceFile, locale: languageSettings.currentLocale), systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .frame(minHeight: 200, maxHeight: 280)
    }

    /// 在线 URL 资源加载中的占位区域
    private var remoteLoadingArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }

            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)

                Text(L10n.text(.playerRemoteLoadingTitle))
                    .font(.headline)

                Text(L10n.text(.playerRemoteLoadingHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .frame(minHeight: 200, maxHeight: 280)
    }

    // MARK: - URL 输入区域

    private var urlInputSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                TextField(L10n.string(.playerURLPlaceholder, locale: languageSettings.currentLocale), text: $viewModel.urlInputText)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif

                // 粘贴按钮
                Button {
                    pasteFromClipboard()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(L10n.string(.commonPaste, locale: languageSettings.currentLocale))

                // 清空按钮
                if !viewModel.urlInputText.isEmpty {
                    Button {
                        viewModel.urlInputText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.string(.commonClear, locale: languageSettings.currentLocale))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                    }
            }

            // 加载按钮
            Button {
                Task { await viewModel.loadFromURL() }
            } label: {
                HStack(spacing: 6) {
                    if viewModel.isDownloading {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.text(.playerActionLoading))
                    } else {
                        Image(systemName: "arrow.down.circle")
                        Text(L10n.text(.playerActionLoadOnlineFile))
                    }
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(
                viewModel.urlInputText
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || viewModel.isDownloading
            )
        }
    }

    /// 从剪贴板粘贴内容到 URL 输入框
    private func pasteFromClipboard() {
        #if os(macOS)
        if let string = NSPasteboard.general.string(forType: .string) {
            viewModel.urlInputText = string
        }
        #else
        if let string = UIPasteboard.general.string {
            viewModel.urlInputText = string
        }
        #endif
    }

    #if os(iOS)
    /// 点击页面空白区域时收起键盘
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
    #endif

    // MARK: - 播放控制条

    private var playerControlsSection: some View {
        VStack(spacing: 12) {
            // 进度条
            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { isSeeking ? seekProgress : viewModel.progress },
                        set: { newValue in
                            isSeeking = true
                            seekProgress = newValue
                        }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if !editing {
                            // 拖拽结束，执行 seek
                            let targetTime = seekProgress * viewModel.duration
                            Task {
                                await viewModel.seek(to: targetTime)
                                isSeeking = false
                            }
                        }
                    }
                )
                .tint(.accentColor)

                // 时间标签
                HStack {
                    Text(isSeeking
                         ? PlayerViewModel.formatTimeStatic(seekProgress * viewModel.duration)
                         : viewModel.formattedCurrentTime)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(viewModel.formattedDuration)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            // 播放按钮
            HStack(spacing: 20) {
                Spacer()

                // 后退 10 秒
                Button {
                    Task { await viewModel.seek(to: viewModel.currentTime - 10) }
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(!viewModel.hasFile)

                // 播放/暂停
                Button {
                    Task {
                        if viewModel.isPlaying {
                            viewModel.pause()
                        } else {
                            await viewModel.play()
                        }
                    }
                } label: {
                    Image(systemName: playButtonIcon)
                        .font(.system(size: 36))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
                .disabled(!viewModel.hasFile || viewModel.isLoading)

                // 前进 10 秒
                Button {
                    Task { await viewModel.seek(to: viewModel.currentTime + 10) }
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(!viewModel.hasFile)

                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
        }
    }

    // MARK: - 流式状态

    private var streamStatusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(L10n.string(.playerSectionPipeline, locale: languageSettings.currentLocale), systemImage: "waveform.path.ecg")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(viewModel.streamStatusText.isEmpty ? L10n.string(.commonEmDash, locale: languageSettings.currentLocale) : viewModel.streamStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let startup = viewModel.playbackMetrics.startupLatencyMs {
                Text(L10n.string(.playerMetricStartupLatency, locale: languageSettings.currentLocale, startup))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(startup > viewModel.releaseGate.startupLatencyMs ? .orange : .secondary)
            }

            if let reason = viewModel.playbackMetrics.fallbackReason {
                Text(L10n.string(.playerMetricFallbackReason, locale: languageSettings.currentLocale, reason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
        }
    }

    private var playbackStateKey: L10nKey {
        if viewModel.isPlaying {
            return viewModel.denoiseEnabled ? .playerStateDenoisingPlayback : .playerStateOriginalPlayback
        }
        return .playerStateReady
    }

    /// 播放按钮图标
    private var playButtonIcon: String {
        if viewModel.isLoading {
            return "hourglass.circle.fill"
        } else if viewModel.isPlaying {
            return "pause.circle.fill"
        } else if viewModel.isFinished {
            return "arrow.counterclockwise.circle.fill"
        } else {
            return "play.circle.fill"
        }
    }

    // MARK: - 降噪与音量设置

    private var settingsSection: some View {
        VStack(spacing: 12) {
            // 降噪开关 & 强度
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(L10n.string(.playerSectionDenoiseSettings, locale: languageSettings.currentLocale), systemImage: "wand.and.stars")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Toggle(L10n.string(.playerToggleEnableDenoise, locale: languageSettings.currentLocale), isOn: $viewModel.denoiseEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .disabled(viewModel.isPlaying)

                    Text(viewModel.denoiseEnabled ? L10n.text(.playerStateEnabled) : L10n.text(.playerStateDisabled))
                        .font(.caption)
                        .foregroundStyle(viewModel.denoiseEnabled ? .green : .secondary)
                }

                if viewModel.denoiseEnabled {
                    HStack(spacing: 12) {
                        Text(L10n.text(.commonLight))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 30)

                        Slider(value: $viewModel.denoiseStrength, in: 0.1...1.0, step: 0.1)
                            .tint(.accentColor)
                            .disabled(viewModel.isPlaying)

                        Text(L10n.text(.commonStrong))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 30)

                        Text("\(Int(viewModel.denoiseStrength * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 36)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial)
            }

            // 音量控制
            VStack(alignment: .leading, spacing: 8) {
                Label(L10n.string(.playerSectionVolume, locale: languageSettings.currentLocale), systemImage: volumeIcon)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Image(systemName: "speaker.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)

                    Slider(value: $viewModel.volume, in: 0...1)
                        .tint(.accentColor)

                    Image(systemName: "speaker.wave.3.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)

                    Text("\(Int(viewModel.volume * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial)
            }
        }
    }

    /// 音量图标
    private var volumeIcon: String {
        if viewModel.volume == 0 {
            return "speaker.slash.fill"
        } else if viewModel.volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if viewModel.volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    /// 仅在媒体加载完成后展示控制面板，避免加载中闪现旧/无效状态。
    private var shouldShowLoadedPanels: Bool {
        viewModel.hasFile && !viewModel.isDownloading
    }

    // MARK: - 导入中遮罩

    #if os(iOS)
    /// 从相册导入时的 loading 遮罩
    private var importingOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)

                Text(L10n.text(.commonImportingAlbum))
                    .font(.headline)
                    .foregroundStyle(.white)

                Text(L10n.text(.commonImportingAlbumHint))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(32)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            }
        }
        .allowsHitTesting(true)
    }
    #endif
}

// MARK: - PlayerViewModel 辅助扩展

extension PlayerViewModel {
    /// 静态时间格式化（供 View 内 Binding 使用）
    nonisolated static func formatTimeStatic(_ time: TimeInterval) -> String {
        let totalSeconds = Int(max(0, time))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    DenoisePlayerView()
        .environmentObject(LanguageSettings())
    #if os(macOS)
        .frame(width: 700, height: 600)
    #endif
}
