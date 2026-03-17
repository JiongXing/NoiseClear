# Repository Guidelines

## Project Structure & Module Organization
`NoiseClear/` contains the app target. Keep UI in `Views/`, state and orchestration in `ViewModels/`, domain data in `Models/`, and playback/denoise logic in `Services/`. Localization helpers live in `NoiseClear/Localization/`, with user-facing strings in `NoiseClear/Localizable.xcstrings` and `NoiseClear/InfoPlist.xcstrings`. Bundled RNNoise C sources are vendored under `NoiseClear/Libraries/RNNoise/`. Repo-level docs live in `README.md` and `TECHNICAL_SOLUTION.md`; release art and screenshots are under `appstore/`; maintenance scripts are in `scripts/`.

## Build, Test, and Development Commands
Open the project in Xcode with `open NoiseClear.xcodeproj` and run the `NoiseClear` scheme for iOS or macOS.

Useful CLI commands:

```bash
xcodebuild -project NoiseClear.xcodeproj -scheme NoiseClear -configuration Debug build
xcodebuild -project NoiseClear.xcodeproj -scheme NoiseClear analyze
./scripts/l10n_audit.sh
./scripts/bump_build_number.sh [next_build]
```

`build` validates compilation, `analyze` catches static issues, `l10n_audit.sh` checks for hardcoded UI text and missing translations, and `bump_build_number.sh` updates `CURRENT_PROJECT_VERSION` before App Store uploads.

## Coding Style & Naming Conventions
Follow existing Swift style: 4-space indentation, one top-level type per file when practical, `UpperCamelCase` for types, `lowerCamelCase` for properties/functions, and descriptive enum cases. Preserve the MVVM split: SwiftUI views should stay thin, while async media work belongs in `ViewModels/` or `Services/`. New user-facing text should go through `L10n.text(...)` or `L10n.string(...)`; do not hardcode strings in SwiftUI call sites.

## Testing Guidelines
There is currently no separate test target in the project, so every change should at minimum pass `xcodebuild ... build`, `xcodebuild ... analyze`, and targeted manual verification in the relevant platform UI. When adding tests later, mirror the app module name and use `FeatureNameTests.swift` naming.

## Commit & Pull Request Guidelines
Recent history uses short, imperative subjects, often in Chinese, for example `导航栏返回按钮着色` and `appstore assets`. Keep commits focused and the first line concise. Pull requests should describe the user-visible change, note the platform(s) tested, link any related issue, and include screenshots or screen recordings for UI or localization updates.

## Localization & Release Notes
If you add a language or string key, update `NoiseClear/Localization/L10nKey.swift`, `NoiseClear/Localization/LocalizationConfig.swift`, and the relevant `.xcstrings` files together, then rerun `./scripts/l10n_audit.sh`.
