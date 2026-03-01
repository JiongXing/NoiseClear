import Foundation

enum LocalizationConfig {
    static let supportedLanguageCodes: [String] = ["zh-Hans", "zh-Hant", "en"]
    static let fallbackLanguageCode = "en"

    static func bestMatch(preferredLanguages: [String]) -> String {
        for identifier in preferredLanguages {
            if let matched = matchSupportedLanguage(for: identifier) {
                return matched
            }
        }
        return fallbackLanguageCode
    }

    static func matchSupportedLanguage(for identifier: String) -> String? {
        guard !identifier.isEmpty else { return nil }
        let normalized = identifier.replacingOccurrences(of: "_", with: "-")

        if supportedLanguageCodes.contains(normalized) {
            return normalized
        }

        if normalized.hasPrefix("zh") {
            if normalized.contains("Hant") || normalized.contains("TW") || normalized.contains("HK") || normalized.contains("MO") {
                return "zh-Hant"
            }
            return "zh-Hans"
        }

        if normalized.hasPrefix("en") {
            return "en"
        }

        let primary = normalized.split(separator: "-").first.map(String.init) ?? normalized
        return supportedLanguageCodes.first { $0.hasPrefix(primary) }
    }
}
