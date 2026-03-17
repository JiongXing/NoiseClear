//
//  VideoPlayerView.swift
//  NoiseClear
//
//  Created by jxing on 2026/2/15.
//

import AVKit
import SwiftUI

// MARK: - 视频播放视图

#if os(macOS)

/// macOS: 使用 AVPlayerView 的 NSViewRepresentable 包装
///
/// 视频播放时音频由 AVAudioEngine 接管（AVPlayer 静音），
/// 本视图仅负责渲染视频画面。
struct VideoPlayerView: NSViewRepresentable {

    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
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

#else

/// iOS: 使用 AVPlayerViewController 的 UIViewControllerRepresentable 包装
struct VideoPlayerView: UIViewControllerRepresentable {

    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.allowsPictureInPicturePlayback = false
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
}

#endif
