# NoiseClear Architecture Notes

## Contents

1. Reading order
2. Layer boundaries
3. Core feature chains
4. Heuristics for locating code

## Reading Order

- Read `README.md` first for product capability and module names.
- Read `TECHNICAL_SOLUTION.md` when the request touches local streaming playback, remote tap processing, buffering, continuity, or fallback behavior.
- Read view files first for screen entry points.
- Read ViewModels second for orchestration and state transitions.
- Read Services last for algorithmic or pipeline behavior.

## Layer Boundaries

- `Views/`: SwiftUI presentation and user interaction entry points
- `ViewModels/`: State ownership, user flow orchestration, and async task coordination
- `Services/`: Media IO, denoise pipelines, playback engines, and fallback implementation
- `Localization/`: Stable localization keys, accessors, and language config

Keep these boundaries intact when deciding where a described feature likely lives.

## Core Feature Chains

### Home To Feature Page

- `ContentView` defines the top-level feature cards
- Current feature pages:
  - `DenoisePlayerView`
  - `FileConversionView`
- Settings drawer is presented from the home screen, not as a separate tab

### Local Real-Time Playback

- UI entry: `DenoisePlayerView`
- State owner: `PlayerViewModel`
- Pipeline:
  - `StreamingAudioPipeline`
  - `IncrementalStreamingDenoiser`
  - `AudioEnginePlayer`
  - `RNNoiseProcessor`

### Remote URL Playback

- UI entry: `DenoisePlayerView`
- State owner: `PlayerViewModel`
- Pipeline:
  - `AVPlayer`
  - `AVPlayerDenoiseTapProcessor`
  - `AVAssetAsyncLoader`
- Fallbacks:
  - Audio tap attach failure -> remote original audio
  - Remote stream prepare failure -> download then local playback

### Offline Batch Conversion

- UI entry: `FileConversionView`
- State owner: `AudioViewModel`
- Pipeline:
  - file import placeholder stage
  - duration/waveform preload
  - `FFmpegDenoiser`
  - export / share

### Localization

- UI reads strings through `L10n.text(...)` or `L10n.string(...)`
- Key definitions live in `Localization/L10nKey.swift`
- Supported language list lives in `Localization/LocalizationConfig.swift`
- Runtime selection lives in `Models/LanguageSettings.swift`

## Heuristics For Locating Code

- If the request sounds like a user journey, start from the page view.
- If the request mentions "状态", "流程", "回退", "是否允许", "何时显示", start from the ViewModel.
- If the request mentions "算法", "引擎", "解码", "重采样", "缓冲", "Tap", "FFmpeg", start from `Services/`.
- If the request mentions "文案", "语言", "翻译", "国际化", jump straight to `Localization/` and `.xcstrings`.
- If the request uses old naming like `VoiceClear`, map it to current `NoiseClear` paths before searching.
