//
//  VoiceClearApp.swift
//  VoiceClear
//
//  Created by jxing on 2026/2/12.
//

import SwiftUI

@main
struct VoiceClearApp: App {
    @StateObject private var languageSettings = LanguageSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(languageSettings)
                .environment(\.locale, languageSettings.currentLocale)
        }
        #if os(macOS)
        .defaultSize(width: 1024, height: 768)
        .windowResizability(.automatic)
        #endif
    }
}
