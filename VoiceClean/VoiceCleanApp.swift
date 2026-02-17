//
//  VoiceCleanApp.swift
//  VoiceClean
//
//  Created by jxing on 2026/2/12.
//

import SwiftUI

@main
struct VoiceCleanApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .defaultSize(width: 700, height: 550)
        .windowResizability(.contentSize)
        #endif
    }
}
