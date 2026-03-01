# VoiceClear

> 基于 RNNoise 的 Apple 平台音视频人声降噪工具，支持本地与在线流式播放降噪。

VoiceClear 是一款使用 SwiftUI + AVFoundation 构建的原生应用。项目核心是 RNNoise 实时降噪，围绕低延迟播放、在线可用性与稳定回退进行了工程化封装。

详细技术文档见：[TECHNICAL_SOLUTION.md](TECHNICAL_SOLUTION.md)

## 主要能力

- 音频降噪：支持 `mp3`、`m4a`、`wav`、`aac`、`aiff`、`flac`
- 视频降噪：支持 `mp4`、`mov`（视频轨直通，仅处理音轨）
- 本地真流式播放：增量解码 + 小帧 RNNoise 处理
- 在线 URL 播放：`http/https` 资源优先走实时降噪
- 多级回退：Tap 失败回退在线原声，远端初始化失败回退下载本地播放
- 降噪强度可调：`10% ~ 100%`
- 多语言 UI：简体中文、繁體中文、English、日本語（可在设置中切换）

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
- 稳定 key：`L10nKey`（点分层英文命名，如 `player.error.invalid_http_url`）
- 统一入口：`L10n.text(...)`（UI）与 `L10n.string(...)`（运行时字符串）
- 语言配置：`LocalizationConfig`（支持语言与 fallback 语言）
- 语言状态：`LanguageSettings`（首次启动跟随系统语言；用户选择后持久化到 `app.language`）
- 缺失翻译策略：先查当前语言 -> 回退 `en` -> 输出 `[missing:key]` 并记录日志（一次）

## 多语言开发规范

### 新增语言

1. 在 `VoiceClear/Localization/LocalizationConfig.swift` 的 `supportedLanguageCodes` 增加语言代码（如 `ja`）
2. 在 `VoiceClear/Localizable.xcstrings` 为全部 key 增加该语言翻译
3. 如有系统权限文案，补充 `VoiceClear/InfoPlist.xcstrings`
4. 运行 `./scripts/l10n_audit.sh`

### 新增文案

1. 在 `VoiceClear/Localization/L10nKey.swift` 新增稳定 key（按模块命名）
2. 在 `VoiceClear/Localizable.xcstrings` 增加对应翻译（`en/zh-Hans/zh-Hant`）
3. 代码中使用 `L10n.text(.newKey)` 或 `L10n.string(.newKey, ...)`，不要直接写硬编码文案
4. 运行 `./scripts/l10n_audit.sh` 检查硬编码与翻译缺失

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
├── Localization/
│   ├── L10nKey.swift
│   ├── L10n.swift
│   └── LocalizationConfig.swift
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

## 近期高价值优化（2026 Q1）

### 1) 本地导入体验优化（避免主线程卡顿）

- 导入链路由“单阶段重处理”升级为“两阶段导入”：
  - 阶段 A：文件先快速入列（占位项）
  - 阶段 B：后台异步补全时长与波形
- 导入弹窗进度改为不确定态（`ProgressView()`），避免展示不准确百分比
- 支持导入取消：可在导入中断并清理仍未完成的占位项

收益：

- 文件选择后 UI 可立即响应，显著降低“卡住”感
- 大文件导入时用户可取消，控制权更明确

### 2) 批量降噪支持“停止处理”

- 新增处理中“停止降噪”按钮
- `AudioViewModel` 增加处理中止控制流（停止当前 + 阻止后续文件继续处理）
- `FFmpegDenoiser` 增加取消令牌与循环检查点，音频/视频处理均可尽快退出

收益：

- 批量任务可中途终止，避免长任务不可控
- 取消后状态回归可重试，失败提示噪音减少

### 3) 媒体加载稳定性增强（MP4 导入/读取）

- 修复 `AVAsset` 异步属性加载在同步桥接中的超时与潜在并发风险
- 调整超时策略并强化后台执行路径
- 补充调试日志，定位 `duration/tracks` 加载失败原因更直接

收益：

- `mp4/mov` 的时长与音轨读取稳定性提升
- 文件转换页与播放页行为一致性更好

### 4) 全链路文案国际化收敛

- 新增交互文案（导入中、停止降噪、处理取消等）全部接入 `L10nKey + Localizable.xcstrings`
- 统一覆盖 `zh-Hans / zh-Hant / en / ja`

收益：

- 多语言版本体验一致
- 后续功能迭代可按 key 规范继续扩展
