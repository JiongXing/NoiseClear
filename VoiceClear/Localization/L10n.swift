import Foundation
import OSLog
import SwiftUI

enum L10n {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceClear", category: "Localization")
    private static let lock = NSLock()
    private static var missingLogged = Set<String>()
    private static var currentLocaleStorage = Locale(identifier: LocalizationConfig.fallbackLanguageCode)

    static func setCurrentLocale(_ locale: Locale) {
        lock.lock()
        currentLocaleStorage = locale
        lock.unlock()
    }

    static var currentLocale: Locale {
        lock.lock()
        defer { lock.unlock() }
        return currentLocaleStorage
    }

    static func text(_ key: L10nKey) -> LocalizedStringKey {
        LocalizedStringKey(key.rawValue)
    }

    static func string(_ key: L10nKey, locale: Locale? = nil) -> String {
        localizedString(for: key.rawValue, locale: locale ?? currentLocale)
    }

    static func string(_ key: L10nKey, locale: Locale? = nil, _ args: CVarArg...) -> String {
        String(format: string(key, locale: locale), locale: locale ?? currentLocale, arguments: args)
    }

    static func string(_ key: L10nKey, _ args: CVarArg...) -> String {
        String(format: string(key, locale: currentLocale), locale: currentLocale, arguments: args)
    }

    private static func localizedString(for key: String, locale: Locale) -> String {
        let primaryCode = LocalizationConfig.matchSupportedLanguage(for: locale.identifier)
            ?? LocalizationConfig.fallbackLanguageCode

        if let primary = lookup(key: key, languageCode: primaryCode) {
            return primary
        }

        if primaryCode != LocalizationConfig.fallbackLanguageCode,
           let fallback = lookup(key: key, languageCode: LocalizationConfig.fallbackLanguageCode) {
            warnMissingOnce(key: key, locale: primaryCode)
            return fallback
        }

        warnMissingOnce(key: key, locale: primaryCode)
        return "[missing:\(key)]"
    }

    private static func lookup(key: String, languageCode: String) -> String? {
        guard let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else {
            return nil
        }
        let value = bundle.localizedString(forKey: key, value: nil, table: nil)
        return value == key ? nil : value
    }

    private static func warnMissingOnce(key: String, locale: String) {
        lock.lock()
        let signature = "\(locale)|\(key)"
        if missingLogged.contains(signature) {
            lock.unlock()
            return
        }
        missingLogged.insert(signature)
        lock.unlock()
        logger.warning("Missing localized string. locale=\(locale, privacy: .public), key=\(key, privacy: .public)")
    }
}
