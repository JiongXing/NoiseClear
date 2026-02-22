//
//  DenoisePlayerView.swift
//  VoiceClean
//
//  Created by jxing on 2026/2/15.
//

import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

// MARK: - 降噪播放页面

/// 实时降噪播放功能：边播放边降噪，支持音频和视频文件
struct DenoisePlayerView: View {

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
                if viewModel.hasFile {
                    playerControlsSection
                }

                // 降噪 & 音量控制
                if viewModel.hasFile {
                    settingsSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color.platformBackground)
        .toolbar {
            if viewModel.hasFile {
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
        .confirmationDialog("选择文件来源", isPresented: $showSourceDialog) {
            Button("从文件选取") {
                viewModel.showFilePicker = true
            }
            Button("从相册选取视频") {
                viewModel.showPhotoPicker = true
            }
            Button("取消", role: .cancel) {}
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
                        viewModel.errorMessage = String(localized: "Cannot read selected video")
                        viewModel.showError = true
                    }
                } catch {
                    viewModel.errorMessage = String(format: String(localized: "Import from album failed: %@"), error.localizedDescription)
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
        .alert("错误", isPresented: $viewModel.showError) {
            Button("确定", role: .cancel) {}
        } message: {
            if let msg = viewModel.errorMessage {
                Text(msg)
            }
        }
    }

    // MARK: - 媒体展示区域

    @ViewBuilder
    private var mediaDisplayArea: some View {
        if let _ = viewModel.currentFile {
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

                    Text("或")
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

                    Text(viewModel.isPlaying
                         ? (viewModel.denoiseEnabled ? "降噪播放中" : "原始播放中")
                         : "准备就绪")
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
                        Label("更换文件", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
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

                TextField("输入在线音频/视频 URL", text: $viewModel.urlInputText)
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
                .help("粘贴")

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
                    .help("清空")
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
                        Text("下载中...")
                    } else {
                        Image(systemName: "arrow.down.circle")
                        Text("加载在线文件")
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
                    Label("降噪设置", systemImage: "wand.and.stars")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Toggle("启用降噪", isOn: $viewModel.denoiseEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .disabled(viewModel.isPlaying)

                    Text(viewModel.denoiseEnabled ? "已启用" : "已关闭")
                        .font(.caption)
                        .foregroundStyle(viewModel.denoiseEnabled ? .green : .secondary)
                }

                if viewModel.denoiseEnabled {
                    HStack(spacing: 12) {
                        Text("轻度")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 30)

                        Slider(value: $viewModel.denoiseStrength, in: 0.1...1.0, step: 0.1)
                            .tint(.accentColor)
                            .disabled(viewModel.isPlaying)

                        Text("强力")
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
                Label("音量", systemImage: volumeIcon)
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

                Text("正在从相册导入...")
                    .font(.headline)
                    .foregroundStyle(.white)

                Text("大文件可能需要较长时间")
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
    #if os(macOS)
        .frame(width: 700, height: 600)
    #endif
}
