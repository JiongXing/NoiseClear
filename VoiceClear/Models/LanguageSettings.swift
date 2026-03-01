import Combine
import Foundation
import SwiftUI

struct AppLanguage: Identifiable, Hashable {
    let code: String

    var id: String { code }
    var locale: Locale { Locale(identifier: code) }

    var nameKey: L10nKey {
        switch code {
        case "zh-Hans": return .settingsLanguageNameZhHans
        case "zh-Hant": return .settingsLanguageNameZhHant
        default: return .settingsLanguageNameEn
        }
    }

    var subtitleKey: L10nKey {
        switch code {
        case "zh-Hans": return .settingsLanguageSubtitleZhHans
        case "zh-Hant": return .settingsLanguageSubtitleZhHant
        default: return .settingsLanguageSubtitleEn
        }
    }

    static var supported: [AppLanguage] {
        LocalizationConfig.supportedLanguageCodes.map { AppLanguage(code: $0) }
    }
}

final class LanguageSettings: ObservableObject {
    private enum Keys {
        static let appLanguage = "app.language"
    }

    @Published var selectedLanguage: AppLanguage {
        didSet {
            guard oldValue != selectedLanguage else { return }
            UserDefaults.standard.set(selectedLanguage.code, forKey: Keys.appLanguage)
            L10n.setCurrentLocale(selectedLanguage.locale)
        }
    }

    var currentLocale: Locale { selectedLanguage.locale }
    var locale: Locale { currentLocale }
    var availableLanguages: [AppLanguage] { AppLanguage.supported }

    init() {
        let storedCode = UserDefaults.standard.string(forKey: Keys.appLanguage)
        if let code = storedCode,
           let matched = LocalizationConfig.matchSupportedLanguage(for: code) {
            selectedLanguage = AppLanguage(code: matched)
        } else {
            let best = LocalizationConfig.bestMatch(preferredLanguages: Locale.preferredLanguages)
            selectedLanguage = AppLanguage(code: best)
        }
        L10n.setCurrentLocale(selectedLanguage.locale)
    }
}
