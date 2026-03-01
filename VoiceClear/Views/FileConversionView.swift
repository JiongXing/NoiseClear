//
//  FileConversionView.swift
//  VoiceClear
//
//  Created by jxing on 2026/2/15.
//

import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

// MARK: - 文件转换页面

/// 批量文件降噪转换功能（从原 ContentView 迁移）
struct FileConversionView: View {
    @EnvironmentObject private var languageSettings: LanguageSettings

    @State private var viewModel = AudioViewModel()

    #if os(iOS)
    /// 是否显示文件来源选择对话框
    @State private var showSourceDialog = false

    /// 相册选择器选中的项目
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    #endif

    var body: some View {
        VStack(spacing: 0) {
            // 主内容区域
            ScrollView {
                VStack(spacing: 16) {
                    // 拖拽区域
                    DropZoneView(
                        onDrop: { urls in
                            Task { await viewModel.addFiles(from: urls) }
                        },
                        onTap: {
                            #if os(macOS)
                            Task { await viewModel.addFiles() }
                            #else
                            showSourceDialog = true
                            #endif
                        }
                    )

                    // 文件列表
                    if !viewModel.audioFiles.isEmpty {
                        fileListSection
                    }

                    // 波形预览（选中文件时显示）
                    if let selectedFile = selectedFile {
                        waveformSection(for: selectedFile)
                    }

                    // 降噪控制
                    if !viewModel.audioFiles.isEmpty {
                        controlsSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }

            // 底部操作栏
            if !viewModel.audioFiles.isEmpty {
                Divider()
                    .padding(.horizontal, 16)

                bottomBar
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
        }
        .background(Color.platformBackground)
        .toolbar {
            if !viewModel.audioFiles.isEmpty {
                ToolbarItem(placement: .automatic) {
                    HStack(spacing: 12) {
                        Label(
                            L10n.string(.commonFilesCount, locale: languageSettings.currentLocale, Int64(viewModel.audioFiles.count)),
                            systemImage: "doc.on.doc"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        let completed = viewModel.audioFiles.filter { $0.status.isCompleted }.count
                        if completed > 0 {
                            Label(
                                L10n.string(.commonCompletedCount, locale: languageSettings.currentLocale, Int64(completed)),
                                systemImage: "checkmark.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.green)
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .fileImporter(
            isPresented: $viewModel.showFilePicker,
            allowedContentTypes: [.audio, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await viewModel.addFiles(from: urls) }
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
            matching: .videos
        )
        .onChange(of: selectedPhotoItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                viewModel.isImporting = true
                defer { viewModel.isImporting = false }
                var importedURLs: [URL] = []
                for item in newItems {
                    do {
                        if let movie = try await item.loadTransferable(type: TransferableMovie.self) {
                            importedURLs.append(movie.url)
                        }
                    } catch {
                        viewModel.errorMessage = L10n.string(.conversionErrorImportAlbumFailed, locale: languageSettings.currentLocale, error.localizedDescription)
                        viewModel.showError = true
                    }
                }
                if !importedURLs.isEmpty {
                    await viewModel.addFiles(from: importedURLs)
                }
                selectedPhotoItems = []
            }
        }
        .overlay {
            if viewModel.isImporting {
                importingOverlay
            }
        }
        .onChange(of: viewModel.showShareSheet) { _, show in
            if show {
                let urls = viewModel.pendingExportURLs
                viewModel.showShareSheet = false
                guard !urls.isEmpty else { return }
                presentShareSheet(items: urls)
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
    }

    // MARK: - 当前选中的文件

    private var selectedFile: AudioFileItem? {
        guard let id = viewModel.selectedFileID else {
            return viewModel.audioFiles.first
        }
        return viewModel.audioFiles.first { $0.id == id }
    }

    // MARK: - 文件列表区域

    private var fileListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L10n.string(.conversionSectionFileList, locale: languageSettings.currentLocale), systemImage: "list.bullet")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Spacer()

                if viewModel.audioFiles.count > 1 && !viewModel.isProcessing {
                    Button(L10n.string(.conversionActionClearAll, locale: languageSettings.currentLocale), role: .destructive) {
                        viewModel.removeAll()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }

            FileListView(
                files: viewModel.audioFiles,
                selectedID: viewModel.selectedFileID ?? viewModel.audioFiles.first?.id,
                onSelect: { id in
                    viewModel.selectedFileID = id
                },
                onRemove: { file in
                    viewModel.removeFile(file)
                },
                onExport: { file in
                    Task { await viewModel.exportFile(file) }
                }
            )
            .frame(minHeight: 60, maxHeight: 200)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - 波形预览区域

    private func waveformSection(for file: AudioFileItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.string(.conversionWaveformPreview, locale: languageSettings.currentLocale, file.fileName), systemImage: "waveform")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            WaveformComparisonView(
                originalSamples: file.waveformSamples,
                processedSamples: file.processedWaveformSamples
            )
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial)
            }
        }
    }

    // MARK: - 降噪控制区域

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.string(.conversionSectionDenoiseStrength, locale: languageSettings.currentLocale), systemImage: "slider.horizontal.3")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text(L10n.text(.commonLight))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Slider(value: $viewModel.denoiseStrength, in: 0.1...1.0, step: 0.1)
                    .tint(.accentColor)
                    .disabled(viewModel.isProcessing)

                Text(L10n.text(.commonStrong))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Text("\(Int(viewModel.denoiseStrength * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial)
            }
        }
    }

    // MARK: - 底部操作栏

    private var bottomBar: some View {
        HStack {
            // 整体进度
            if viewModel.isProcessing {
                ProgressView(value: viewModel.overallProgress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 200)
                    .tint(.accentColor)

                Text("\(Int(viewModel.overallProgress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36)

                if let remaining = viewModel.estimatedRemainingSeconds, remaining >= 5 {
                    Text(L10n.string(.conversionLabelRemaining, locale: languageSettings.currentLocale, formatRemainingTime(remaining)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            HStack(spacing: 12) {
                // 导出全部
                if viewModel.hasCompletedFiles {
                    Button {
                        Task { await viewModel.exportAll() }
                    } label: {
                        Label(L10n.string(.conversionActionExportAll, locale: languageSettings.currentLocale), systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isProcessing)
                }

                // 开始降噪（处理中时只显示图标，避免文案换行挤压空间）
                Button {
                    Task { await viewModel.processAll() }
                } label: {
                    if viewModel.isProcessing {
                        Image(systemName: "hourglass")
                    } else {
                        Label(L10n.string(.conversionActionStartDenoise, locale: languageSettings.currentLocale), systemImage: "wand.and.stars")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isProcessing || !viewModel.hasFilesToProcess)
            }
        }
    }

    // MARK: - 工具方法

    /// 将秒数格式化为本地化的「X分Y秒」或「Y秒」
    private func formatRemainingTime(_ seconds: Double) -> String {
        let locale = languageSettings.currentLocale
        let total = Int(ceil(seconds))
        if total >= 60 {
            let m = Int64(total / 60)
            let s = Int64(total % 60)
            return s > 0
                ? L10n.string(.commonMinutesSeconds, locale: locale, m, s)
                : L10n.string(.commonMinutes, locale: locale, m)
        } else {
            return L10n.string(.commonSeconds, locale: locale, Int64(total))
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

// MARK: - iOS 分享面板

#if os(iOS)
/// 通过 UIKit 直接 present UIActivityViewController，避免 SwiftUI .sheet 包装导致的主线程卡顿
private func presentShareSheet(items: [Any]) {
    guard let windowScene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene }).first,
          let rootVC = windowScene.keyWindow?.rootViewController else { return }

    let topVC = topViewController(from: rootVC)
    let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)

    // iPad 需要 popover 锚点
    if let popover = activityVC.popoverPresentationController {
        popover.sourceView = topVC.view
        popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
        popover.permittedArrowDirections = []
    }

    topVC.present(activityVC, animated: true)
}

/// 递归查找最顶层的 ViewController
private func topViewController(from vc: UIViewController) -> UIViewController {
    if let presented = vc.presentedViewController {
        return topViewController(from: presented)
    }
    if let nav = vc as? UINavigationController, let top = nav.topViewController {
        return topViewController(from: top)
    }
    if let tab = vc as? UITabBarController, let selected = tab.selectedViewController {
        return topViewController(from: selected)
    }
    return vc
}
#endif

#Preview {
    FileConversionView()
        .environmentObject(LanguageSettings())
    #if os(macOS)
        .frame(width: 700, height: 560)
    #endif
}
