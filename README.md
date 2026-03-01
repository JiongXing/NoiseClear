# VoiceClear

> 基于 RNNoise 的 Apple 平台音视频人声降噪工具，支持本地与在线流式播放降噪。

VoiceClear 是一款使用 SwiftUI + AVFoundation 构建的原生应用。项目核心是 RNNoise 实时降噪，围绕低延迟播放、在线可用性与稳定回退进行了工程化封装。

详细技术文档见：[docs/TECHNICAL_SOLUTION.md](docs/TECHNICAL_SOLUTION.md)

## 主要能力

- 音频降噪：支持 `mp3`、`m4a`、`wav`、`aac`、`aiff`、`flac`
- 视频降噪：支持 `mp4`、`mov`（视频轨直通，仅处理音轨）
- 本地真流式播放：增量解码 + 小帧 RNNoise 处理
- 在线 URL 播放：`http/https` 资源优先走实时降噪
- 多级回退：Tap 失败回退在线原声，远端初始化失败回退下载本地播放
- 降噪强度可调：`10% ~ 100%`
- 多语言 UI：简体中文、繁體中文、English（可在设置中切换）

## 技术方案概览

### 1) 本地播放主路径

`IncrementalStreamingDenoiser` + `AudioEnginePlayer`

- 增量读取媒体，持续产出 PCM 小块
- 以 RNNoise 帧长（480 samples）逐帧处理
- 管线内部控制缓冲水位（约 2 秒队列上限）
- 在块边界做平滑，减少爆破音和边界突变

### 2) 在线播放主路径

`AVPlayerItem + MTAudioProcessingTap + AVPlayerDenoiseTapProcessor`

- 直接播放远端媒体
- 在 Audio Tap 回调中执行 RNNoise
- 使用 `rnPendingSamples/sourcePendingSamples` 维持跨回调连续样本消费，避免逐包重映射导致的拖音/重音
- 对边界做平滑过渡，提升长时听感稳定性

### 3) 回退策略

- Audio Tap 挂载失败 -> 在线原声播放
- 远端初始化失败 -> 下载后走本地链路播放
- 所有回退原因记录到 `playbackMetrics.fallbackReason`

## 架构与封装

### MVVM 分层

- `AudioViewModel`：批量降噪、进度、导出
- `PlayerViewModel`：播放状态机、链路选择、回退策略、启动时延指标
- `Services`：解码/重采样/降噪/调度/媒体 I/O

### 关键模块职责

- `StreamingAudioPipeline`：统一本地流式读取接口
- `IncrementalStreamingDenoiser`：当前本地流式主实现
- `StreamingDenoiser`：legacy 兼容实现（可切换）
- `AVPlayerDenoiseTapProcessor`：在线音轨实时降噪核心
- `AudioEnginePlayer`：AVAudioEngine 播放与缓冲池优化
- `FFmpegDenoiser`：离线降噪处理入口（音频输出 WAV，视频重封装）
- `LanguageSettings`：运行时语言与 locale 注入

## 多语言实现

- 文案资源：`Localizable.xcstrings`
- 语言模型：`AppLanguage`（`zh-Hans` / `zh-Hant` / `en`）
- App 启动时通过 `.environment(\.locale, languageSettings.locale)` 注入当前语言
- `Text(LocalizedStringKey)` 与 `LocaleLocalizer` 并行支持，覆盖普通 UI 与运行时提示（如错误、Toast）

## 支持格式与输出规则

- 输入音频：`mp3`, `m4a`, `wav`, `aac`, `aiff`, `flac`
- 输入视频：`mp4`, `mov`
- 离线导出：
  - 音频 -> `WAV`（`16kHz`, mono, Float32）
  - 视频 -> 保持原容器（`mp4/mov`），视频轨直通，音轨降噪后编码
- 在线 URL：校验 `http/https`，并结合扩展名与 MIME 推断媒体类型

## 项目结构（核心）

```text
VoiceClear/
├── VoiceClearApp.swift
├── ContentView.swift
├── Localizable.xcstrings
├── Models/
│   ├── AudioFileItem.swift
│   └── LanguageSettings.swift
├── ViewModels/
│   ├── AudioViewModel.swift
│   └── PlayerViewModel.swift
├── Services/
│   ├── StreamingAudioPipeline.swift
│   ├── IncrementalStreamingDenoiser.swift
│   ├── StreamingDenoiser.swift
│   ├── AVPlayerDenoiseTapProcessor.swift
│   ├── AVAssetAsyncLoader.swift
│   ├── AudioEnginePlayer.swift
│   ├── AudioFileService.swift
│   ├── RNNoiseProcessor.swift
│   └── FFmpegDenoiser.swift
└── Views/
    ├── DenoisePlayerView.swift
    ├── VideoPlayerView.swift
    ├── FileConversionView.swift
    └── SettingsDrawerView.swift
```

## 技术栈

- 平台：macOS / iOS（SwiftUI）
- 架构：MVVM + Observation（`@Observable`）
- 降噪：RNNoise C 库（内置编译）
- 媒体：AVFoundation + AVPlayer Audio Tap
- 并发：Swift Concurrency + GCD

## 开发环境

- Xcode 16+
- 部署目标（Target）：
  - iOS 17+
  - macOS 14+

## 运行与调试

1. 打开 `VoiceClear.xcodeproj`
2. 选择目标平台（iOS 或 macOS）
3. 直接运行 `VoiceClear` target

## 许可证

本项目基于 [GNU General Public License v3.0](LICENSE) 开源。
