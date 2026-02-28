//
//  LanguageSettings.swift
//  VoiceClear
//
//  Created by Cursor on 2026/2/28.
//

import Foundation
import SwiftUI
import Combine

enum AppLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"

    var id: String { rawValue }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    var localizedName: String {
        switch self {
        case .simplifiedChinese:
            String(localized: "简体中文")
        case .traditionalChinese:
            String(localized: "繁體中文")
        case .english:
            String(localized: "English")
        }
    }

    var localizedSubtitle: String {
        switch self {
        case .simplifiedChinese:
            String(localized: "推荐中国大陆用户")
        case .traditionalChinese:
            String(localized: "推薦繁體中文使用者")
        case .english:
            String(localized: "Recommended for global users")
        }
    }
}

final class LanguageSettings: ObservableObject {
    private enum Keys {
        static let appLanguage = "app.language"
    }

    @Published var selectedLanguage: AppLanguage {
        didSet {
            guard oldValue != selectedLanguage else { return }
            UserDefaults.standard.set(selectedLanguage.rawValue, forKey: Keys.appLanguage)
        }
    }

    init() {
        let storedValue = UserDefaults.standard.string(forKey: Keys.appLanguage)
        selectedLanguage = AppLanguage(rawValue: storedValue ?? "") ?? .simplifiedChinese
    }
}
