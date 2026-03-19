#!/usr/bin/env python3
"""Map a natural-language feature description to likely NoiseClear files."""

from __future__ import annotations

import sys
from dataclasses import dataclass


@dataclass(frozen=True)
class FeatureTarget:
    name: str
    keywords: tuple[str, ...]
    summary: str
    files: tuple[str, ...]


TARGETS = (
    FeatureTarget(
        name="home",
        keywords=(
            "首页", "home", "功能入口", "功能卡片", "导航", "settings", "设置按钮", "抽屉", "drawer"
        ),
        summary="首页、功能入口卡片、导航跳转、设置抽屉",
        files=(
            "NoiseClear/ContentView.swift",
            "NoiseClear/Views/SettingsDrawerView.swift",
            "NoiseClear/Models/LanguageSettings.swift",
        ),
    ),
    FeatureTarget(
        name="denoise-player",
        keywords=(
            "播放器", "播放页", "播放", "实时降噪", "音频播放", "视频播放", "seek", "进度条", "音量",
            "降噪强度", "本地播放", "replace file", "url", "在线播放", "在线播放", "remote", "stream",
            "streaming", "fallback", "回退", "tap", "avplayer", "拖入文件", "导入后播放"
        ),
        summary="实时降噪播放页，本地/远端播放、进度控制、在线播放和回退",
        files=(
            "NoiseClear/Views/DenoisePlayerView.swift",
            "NoiseClear/ViewModels/PlayerViewModel.swift",
            "NoiseClear/Services/IncrementalStreamingDenoiser.swift",
            "NoiseClear/Services/AudioEnginePlayer.swift",
            "NoiseClear/Services/AVPlayerDenoiseTapProcessor.swift",
            "NoiseClear/Services/AVAssetAsyncLoader.swift",
        ),
    ),
    FeatureTarget(
        name="file-conversion",
        keywords=(
            "文件转换", "批量", "批处理", "导出", "offline", "ffmpeg", "停止处理", "取消处理",
            "导入多个", "文件列表", "波形", "waveform", "share", "conversion", "process all"
        ),
        summary="批量文件降噪、导入预处理、波形预览、导出与停止处理",
        files=(
            "NoiseClear/Views/FileConversionView.swift",
            "NoiseClear/ViewModels/AudioViewModel.swift",
            "NoiseClear/Views/FileListView.swift",
            "NoiseClear/Views/WaveformView.swift",
            "NoiseClear/Services/FFmpegDenoiser.swift",
            "NoiseClear/Services/AudioFileService.swift",
        ),
    ),
    FeatureTarget(
        name="localization",
        keywords=(
            "语言", "多语言", "国际化", "本地化", "文案", "翻译", "key", "xcstrings", "l10n",
            "localization", "locale", "settings language", "missing"
        ),
        summary="语言切换、本地化 key、翻译资源与运行时 locale 注入",
        files=(
            "NoiseClear/Views/SettingsDrawerView.swift",
            "NoiseClear/Models/LanguageSettings.swift",
            "NoiseClear/Localization/L10n.swift",
            "NoiseClear/Localization/L10nKey.swift",
            "NoiseClear/Localization/LocalizationConfig.swift",
            "NoiseClear/Localizable.xcstrings",
            "NoiseClear/InfoPlist.xcstrings",
        ),
    ),
    FeatureTarget(
        name="services-local-playback",
        keywords=(
            "rnnoise", "缓冲", "buffer", "低延迟", "增量", "incremental", "pcm", "音频引擎",
            "audioengine", "平滑", "边界", "小帧", "480", "本地链路"
        ),
        summary="本地实时播放链路的实现细节",
        files=(
            "NoiseClear/ViewModels/PlayerViewModel.swift",
            "NoiseClear/Services/StreamingAudioPipeline.swift",
            "NoiseClear/Services/IncrementalStreamingDenoiser.swift",
            "NoiseClear/Services/AudioEnginePlayer.swift",
            "NoiseClear/Services/RNNoiseProcessor.swift",
        ),
    ),
    FeatureTarget(
        name="services-remote-playback",
        keywords=(
            "远端", "远程", "audio tap", "mtaudioprocessingtap", "original audio", "原声",
            "http", "https", "在线 url", "passthrough", "startup latency", "metrics"
        ),
        summary="远端 URL 播放、Audio Tap、回退与启动指标",
        files=(
            "NoiseClear/ViewModels/PlayerViewModel.swift",
            "NoiseClear/Services/AVPlayerDenoiseTapProcessor.swift",
            "NoiseClear/Services/AVAssetAsyncLoader.swift",
        ),
    ),
)


def normalize(text: str) -> str:
    return " ".join(text.strip().lower().replace("_", " ").replace("-", " ").split())


def score_target(query: str, target: FeatureTarget) -> int:
    score = 0
    for keyword in target.keywords:
        keyword_norm = normalize(keyword)
        if keyword_norm and keyword_norm in query:
            score += max(2, len(keyword_norm))
    return score


def main() -> int:
    query = normalize(" ".join(sys.argv[1:]))
    if not query:
        print("Usage: python3 scripts/find_feature.py \"功能描述\"")
        return 1

    ranked = sorted(
        ((score_target(query, target), target) for target in TARGETS),
        key=lambda item: item[0],
        reverse=True,
    )

    matches = [item for item in ranked if item[0] > 0]
    if not matches:
        print("No strong direct match.")
        print("Read references/feature-map.md and start from NoiseClear/ContentView.swift or the closest page.")
        return 0

    print(f'Query: "{query}"')
    print()
    for index, (score, target) in enumerate(matches[:3], start=1):
        print(f"{index}. {target.name}  score={score}")
        print(f"   Summary: {target.summary}")
        print("   Files:")
        for file_path in target.files:
            print(f"   - {file_path}")
        print()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
