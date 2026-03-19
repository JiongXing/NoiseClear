---
name: noiseclear-feature-locator
description: Understand NoiseClear page and feature architecture, then map natural-language feature descriptions to the corresponding SwiftUI page, ViewModel, service, or localization entry. Use when an agent needs to quickly answer questions like "这个功能在哪个页面", "在线播放降噪逻辑在哪", "设置语言在哪改", "批量转换对应哪些文件", or to decide which files to inspect first for home navigation, real-time playback, online URL playback, import/export, batch denoise, waveform preview, fallback strategy, or localization.
---

# NoiseClear Feature Locator

## Quick Start

Follow this sequence:

1. Read [`references/feature-map.md`](references/feature-map.md) to map the user request to a page, feature entry, and likely owner files.
2. Run `python3 scripts/find_feature.py "<功能描述>"` when the request is vague or uses product language instead of code terms.
3. Read [`references/architecture-notes.md`](references/architecture-notes.md) when the request crosses page boundaries or touches playback pipelines, fallback logic, or localization.
4. Open the returned Swift files and continue implementation or analysis from the most likely page entry point first, then the ViewModel, then the supporting services.

## Workflow

Use this decision path:

- If the request is user-facing and screen-oriented, start from `ContentView` and the page map.
- If the request is about playback state, seek bar, URL streaming, fallback, or real-time denoise, start from `PlayerViewModel`.
- If the request is about file import, batch processing, export, progress, cancel, or waveform preview, start from `AudioViewModel`.
- If the request mentions text, language, translation, or missing strings, jump to the localization notes and then inspect `Localization/` plus `.xcstrings`.
- If the request mentions sound quality, streaming continuity, buffer, Audio Tap, AVPlayer, RNNoise, or FFmpeg, inspect the relevant `Services/` entry after identifying the owning page.

## Search Tips

- Prefer product terms first: "播放", "在线 URL", "批量转换", "设置语言", "导入取消", "波形", "回退", "在线播放原声".
- Use `rg` against `NoiseClear/Views`, `NoiseClear/ViewModels`, `NoiseClear/Services`, and `NoiseClear/Localization` after the feature map narrows the target.
- Read `README.md` before `TECHNICAL_SOLUTION.md` unless the request is specifically about playback chains, low-latency behavior, or fallback implementation.
- Treat `Views` as entry points, `ViewModels` as orchestration owners, and `Services` as implementation owners.

## Resources

- `references/feature-map.md`: Page-level feature lookup, common request phrases, and file ownership.
- `references/architecture-notes.md`: Cross-page architecture, pipeline responsibilities, and doc reading order.
- `scripts/find_feature.py`: Natural-language matcher for quickly narrowing likely pages and owner files.
