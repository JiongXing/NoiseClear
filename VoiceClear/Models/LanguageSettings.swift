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

    /// 本地化键（供 Text(LocalizedStringKey) 使用，可响应 environment locale 变更）
    var nameKey: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        }
    }

    var subtitleKey: String {
        switch self {
        case .simplifiedChinese: return "推荐中国大陆用户"
        case .traditionalChinese: return "推薦繁體中文使用者"
        case .english: return "Recommended for global users"
        }
    }

    var localizedName: String {
        String(localized: String.LocalizationValue(stringLiteral: nameKey))
    }

    var localizedSubtitle: String {
        String(localized: String.LocalizationValue(stringLiteral: subtitleKey))
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

// MARK: - 运行时 locale 指定本地化（用于 Toast 等非 Text 场景）
enum LocaleLocalizer {
    static func string(for key: String, locale: Locale) -> String {
        let id = locale.identifier
        guard let path = Bundle.main.path(forResource: id, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return NSLocalizedString(key, comment: "")
        }
        return bundle.localizedString(forKey: key, value: NSLocalizedString(key, comment: ""), table: nil)
    }
}
