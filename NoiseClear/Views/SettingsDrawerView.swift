//
//  SettingsDrawerView.swift
//  NoiseClear
//
//  Created by Cursor on 2026/2/28.
//

import SwiftUI

struct SettingsDrawerView: View {
    @EnvironmentObject private var languageSettings: LanguageSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            languageSection
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.string(.settingsLanguageTitle, locale: languageSettings.currentLocale), systemImage: "globe")
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(spacing: 10) {
                ForEach(languageSettings.availableLanguages) { language in
                    languageRow(language)
                }
            }
        }
    }

    private func languageRow(_ language: AppLanguage) -> some View {
        let isSelected = languageSettings.selectedLanguage == language
        let backgroundColor = isSelected ? Color.blue.opacity(0.12) : Color.primary.opacity(0.04)
        let borderColor = isSelected ? Color.blue.opacity(0.35) : Color.primary.opacity(0.08)
        let iconName = isSelected ? "checkmark.circle.fill" : "circle"
        let iconColor: Color = isSelected ? .blue : .secondary

        return Button(action: {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                languageSettings.selectedLanguage = language
            }
        }, label: {
            HStack(spacing: 12) {
                Text(L10n.string(language.nameKey, locale: language.locale))
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: iconName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(backgroundColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(borderColor, lineWidth: 1)
                    )
            )
        })
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n.string(language.nameKey, locale: language.locale)))
        .accessibilityValue(Text(isSelected ? L10n.text(.commonSelected) : L10n.text(.commonNotSelected)))
    }
}
