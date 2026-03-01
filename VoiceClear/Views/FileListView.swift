//
//  FileListView.swift
//  VoiceClear
//
//  Created by jxing on 2026/2/12.
//

import SwiftUI

// MARK: - 文件列表视图

/// 显示已添加的音频文件列表
struct FileListView: View {

    let files: [AudioFileItem]
    let selectedID: UUID?
    var onSelect: (UUID) -> Void
    var onRemove: (AudioFileItem) -> Void
    var onExport: (AudioFileItem) -> Void

    var body: some View {
        if files.isEmpty {
            emptyStateView
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(files) { file in
                        AudioFileRow(
                            file: file,
                            isSelected: file.id == selectedID,
                            onRemove: { onRemove(file) },
                            onExport: { onExport(file) }
                        )
                        .onTapGesture {
                            onSelect(file.id)
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(L10n.text(.fileListEmpty))
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }
}

// MARK: - 单个文件行

/// 文件列表中的单行，显示文件信息和状态
struct AudioFileRow: View {
    @EnvironmentObject private var languageSettings: LanguageSettings

    let file: AudioFileItem
    let isSelected: Bool
    var onRemove: () -> Void
    var onExport: () -> Void

    @State private var showRemoveConfirmation = false

    #if os(macOS)
    @State private var isHovered = false
    #endif

    var body: some View {
        HStack(spacing: 12) {
            // 状态图标
            statusIcon
                .frame(width: 28, height: 28)

            // 文件信息
            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileName)
                    .font(.system(.body, design: .default, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    Text(file.formattedDuration)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(file.status.displayText(locale: languageSettings.currentLocale))
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
            }

            Spacer()

            // 进度条（处理中时显示）
            if case .processing(let progress) = file.status {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 80)
                    .tint(.accentColor)
            }

            // 操作按钮 — 增大间距与点击区域，防止误触
            HStack(spacing: 8) {
                if file.status.isCompleted {
                    Button(action: onExport) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    #if os(macOS)
                    .help(L10n.string(.fileListExport))
                    #endif
                }

                if !file.status.isProcessing {
                    Button {
                        showRemoveConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    #if os(macOS)
                    .opacity(isHovered ? 1 : 0)
                    .help(L10n.string(.fileListRemove))
                    #endif
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 8)
                #if os(macOS)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : (isHovered ? Color.primary.opacity(0.04) : .clear))
                #else
                .fill(isSelected ? Color.accentColor.opacity(0.12) : .clear)
                #endif
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
            }
        }
        // 上下文菜单：右键(macOS) / 长按(iOS) 提供操作入口
        .contextMenu {
            if file.status.isCompleted {
                Button {
                    onExport()
                } label: {
                    Label(L10n.string(.fileListExport), systemImage: "square.and.arrow.up")
                }
            }

            if !file.status.isProcessing {
                Divider()
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label(L10n.string(.fileListRemove), systemImage: "trash")
                }
            }
        }
        // 删除确认弹窗，防止误触
        .confirmationDialog(
            L10n.string(.fileListConfirmRemoveTitle, locale: languageSettings.currentLocale),
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string(.fileListRemove, locale: languageSettings.currentLocale), role: .destructive) {
                onRemove()
            }
            Button(L10n.string(.commonCancel, locale: languageSettings.currentLocale), role: .cancel) {}
        } message: {
            Text(L10n.string(.fileListConfirmRemoveMessage, locale: languageSettings.currentLocale, file.fileName))
        }
        #if os(macOS)
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        #endif
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    // MARK: - 子视图

    @ViewBuilder
    private var statusIcon: some View {
        switch file.status {
        case .idle:
            Image(systemName: file.isVideo ? "film" : "music.note")
                .foregroundStyle(.secondary)
                .font(.system(size: 14))

        case .processing:
            ProgressView()
                .controlSize(.small)

        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 16))

        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 14))
        }
    }

    private var statusColor: Color {
        switch file.status {
        case .idle: return .secondary
        case .processing: return .accentColor
        case .completed: return .green
        case .failed: return .red
        }
    }
}

#Preview {
    let files: [AudioFileItem] = [
        AudioFileItem(url: URL(fileURLWithPath: "/test/lecture_01.mp3"), duration: 2730),
        AudioFileItem(url: URL(fileURLWithPath: "/test/lecture_02.mp3"), duration: 4815),
        AudioFileItem(url: URL(fileURLWithPath: "/test/short_clip.mp3"), duration: 300),
    ]

    return FileListView(
        files: files,
        selectedID: files.first?.id,
        onSelect: { _ in },
        onRemove: { _ in },
        onExport: { _ in }
    )
    .environmentObject(LanguageSettings())
    .frame(width: 500, height: 300)
    .padding()
}
