//
//  VideoPlayerView.swift
//  VoiceClean
//
//  Created by jxing on 2026/2/15.
//

import AVKit
import SwiftUI

// MARK: - 视频播放视图

/// 使用 AVPlayerView 显示视频画面的 NSViewRepresentable 包装
///
/// 视频播放时音频由 AVAudioEngine 接管（AVPlayer 静音），
/// 本视图仅负责渲染视频画面。
struct VideoPlayerView: NSViewRepresentable {

    /// AVPlayer 实例（由 PlayerViewModel 管理）
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none  // 隐藏原生控件，使用自定义控件
        view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
