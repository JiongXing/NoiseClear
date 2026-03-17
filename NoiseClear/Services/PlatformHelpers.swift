//
//  PlatformHelpers.swift
//  NoiseClear
//
//  跨平台辅助工具，统一 macOS 和 iOS 的平台差异
//

import SwiftUI

// MARK: - 跨平台 Color 扩展

extension Color {
    /// 跨平台窗口/页面背景色
    static var platformBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}
