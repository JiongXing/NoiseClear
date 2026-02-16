//
//  ContentView.swift
//  VoiceClean
//
//  Created by jxing on 2026/2/12.
//

import SwiftUI

// MARK: - 侧边栏导航项

/// 应用的两大功能模块
enum SidebarItem: String, CaseIterable, Identifiable {
    case denoisePlayer = "降噪播放"
    case fileConversion = "文件转换"

    var id: String { rawValue }

    /// 侧边栏图标
    var icon: String {
        switch self {
        case .fileConversion: return "doc.on.doc"
        case .denoisePlayer:  return "play.circle"
        }
    }

    /// 侧边栏副标题
    var subtitle: String {
        switch self {
        case .fileConversion: return "批量降噪导出"
        case .denoisePlayer:  return "实时降噪试听"
        }
    }
}

// MARK: - 主界面（导航壳）

struct ContentView: View {

    @State private var selectedItem: SidebarItem = .denoisePlayer

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selectedItem) { item in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.rawValue)
                            .font(.body)
                            .fontWeight(.medium)

                        Text(item.subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: item.icon)
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.vertical, 4)
                .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 230)
            .listStyle(.sidebar)
        } detail: {
            switch selectedItem {
            case .fileConversion:
                FileConversionView()
            case .denoisePlayer:
                DenoisePlayerView()
            }
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 980, height: 600)
}
