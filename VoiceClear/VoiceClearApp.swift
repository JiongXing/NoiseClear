//
//  VoiceClearApp.swift
//  VoiceClear
//
//  Created by jxing on 2026/2/12.
//

import SwiftUI

@main
struct VoiceClearApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentSize)
        #endif
    }
}
