# NoiseClear Feature Map

## Contents

1. Page entry points
2. Common feature descriptions
3. File ownership by responsibility
4. Fast search hints

## Page Entry Points

### Home

- Entry: `NoiseClear/ContentView.swift`
- Purpose: App home, navigation to major features, settings drawer toggle
- User phrases:
  "首页"
  "功能卡片"
  "进入播放器"
  "进入文件转换"
  "打开设置"
- Related files:
  - `NoiseClear/ContentView.swift`
  - `NoiseClear/Views/SettingsDrawerView.swift`
  - `NoiseClear/Models/LanguageSettings.swift`

### Real-Time Denoise Player

- Entry: `NoiseClear/Views/DenoisePlayerView.swift`
- ViewModel owner: `NoiseClear/ViewModels/PlayerViewModel.swift`
- Purpose: Load local file or remote URL, play while denoising, seek, adjust strength and volume, show streaming state
- User phrases:
  "实时降噪播放"
  "在线播放"
  "URL 播放"
  "视频播放"
  "音频播放"
  "进度条"
  "播放控制"
  "拖入文件后播放"
  "在线播放失败回退"
- Supporting services:
  - `NoiseClear/Services/IncrementalStreamingDenoiser.swift`
  - `NoiseClear/Services/AudioEnginePlayer.swift`
  - `NoiseClear/Services/AVPlayerDenoiseTapProcessor.swift`
  - `NoiseClear/Services/StreamingAudioPipeline.swift`
  - `NoiseClear/Services/StreamingDenoiser.swift`
  - `NoiseClear/Services/AVAssetAsyncLoader.swift`
  - `NoiseClear/Services/AudioFileService.swift`

### File Conversion / Batch Denoise

- Entry: `NoiseClear/Views/FileConversionView.swift`
- ViewModel owner: `NoiseClear/ViewModels/AudioViewModel.swift`
- Purpose: Import multiple files, preview list and waveform, run offline denoise, export results, stop long-running jobs
- User phrases:
  "文件转换"
  "批量降噪"
  "批量处理"
  "导入多个文件"
  "停止处理"
  "导出文件"
  "波形预览"
  "处理进度"
- Supporting views and services:
  - `NoiseClear/Views/FileListView.swift`
  - `NoiseClear/Views/WaveformView.swift`
  - `NoiseClear/Views/DropZoneView.swift`
  - `NoiseClear/Services/FFmpegDenoiser.swift`
  - `NoiseClear/Services/AudioFileService.swift`

### Settings Drawer / Language Selection

- Entry: `NoiseClear/Views/SettingsDrawerView.swift`
- State owner: `NoiseClear/Models/LanguageSettings.swift`
- Localization infrastructure:
  - `NoiseClear/Localization/L10n.swift`
  - `NoiseClear/Localization/L10nKey.swift`
  - `NoiseClear/Localization/LocalizationConfig.swift`
  - `NoiseClear/Localizable.xcstrings`
  - `NoiseClear/InfoPlist.xcstrings`
- User phrases:
  "设置"
  "切换语言"
  "多语言"
  "国际化"
  "文案 key"
  "翻译缺失"

## Common Feature Descriptions

### "我要改首页上的两个功能入口"

- Start from `NoiseClear/ContentView.swift`
- Look for `FeatureItem`, `navigationDestination`, and feature card UI

### "我要改实时播放页 / 播放器页 / 在线播放页"

- Start from `NoiseClear/Views/DenoisePlayerView.swift`
- Then inspect `NoiseClear/ViewModels/PlayerViewModel.swift`

### "我要改 URL 输入、在线视频/音频播放、回退逻辑"

- Start from `NoiseClear/ViewModels/PlayerViewModel.swift`
- Then inspect:
  - `NoiseClear/Services/AVPlayerDenoiseTapProcessor.swift`
  - `NoiseClear/Services/AVAssetAsyncLoader.swift`
  - `NoiseClear/Services/IncrementalStreamingDenoiser.swift`

### "我要改本地音频播放、流式解码、低延迟降噪"

- Start from `NoiseClear/ViewModels/PlayerViewModel.swift`
- Then inspect:
  - `NoiseClear/Services/StreamingAudioPipeline.swift`
  - `NoiseClear/Services/IncrementalStreamingDenoiser.swift`
  - `NoiseClear/Services/AudioEnginePlayer.swift`
  - `NoiseClear/Services/RNNoiseProcessor.swift`

### "我要改文件批处理、停止处理、导出结果"

- Start from `NoiseClear/Views/FileConversionView.swift`
- Then inspect:
  - `NoiseClear/ViewModels/AudioViewModel.swift`
  - `NoiseClear/Services/FFmpegDenoiser.swift`

### "我要改导入体验、占位项、导入取消、波形加载"

- Start from `NoiseClear/ViewModels/AudioViewModel.swift`
- Then inspect:
  - `NoiseClear/Views/FileConversionView.swift`
  - `NoiseClear/Services/AudioFileService.swift`

### "我要改语言切换、文案、多语言资源"

- Start from `NoiseClear/Views/SettingsDrawerView.swift`
- Then inspect:
  - `NoiseClear/Models/LanguageSettings.swift`
  - `NoiseClear/Localization/L10nKey.swift`
  - `NoiseClear/Localization/L10n.swift`
  - `NoiseClear/Localization/LocalizationConfig.swift`
  - `NoiseClear/Localizable.xcstrings`

## File Ownership By Responsibility

### Views

- `NoiseClear/ContentView.swift`: Home navigation and settings drawer presentation
- `NoiseClear/Views/DenoisePlayerView.swift`: Real-time playback page UI
- `NoiseClear/Views/FileConversionView.swift`: Batch conversion page UI
- `NoiseClear/Views/SettingsDrawerView.swift`: Language settings UI
- `NoiseClear/Views/FileListView.swift`: Batch file list interactions
- `NoiseClear/Views/DropZoneView.swift`: Drag-and-drop / picker entry surface
- `NoiseClear/Views/VideoPlayerView.swift`: Video rendering surface for playback page
- `NoiseClear/Views/WaveformView.swift`: Waveform comparison rendering

### ViewModels

- `NoiseClear/ViewModels/PlayerViewModel.swift`: Playback state machine, local/remote routing, fallback, metrics
- `NoiseClear/ViewModels/AudioViewModel.swift`: Import queue, batch processing, export, stop/cancel, waveform preload

### Services

- `NoiseClear/Services/IncrementalStreamingDenoiser.swift`: Local incremental denoise pipeline
- `NoiseClear/Services/StreamingAudioPipeline.swift`: Shared local streaming contract
- `NoiseClear/Services/StreamingDenoiser.swift`: Legacy local streaming implementation
- `NoiseClear/Services/AudioEnginePlayer.swift`: Buffered playback engine
- `NoiseClear/Services/AVPlayerDenoiseTapProcessor.swift`: Remote AVPlayer audio-tap denoise
- `NoiseClear/Services/AVAssetAsyncLoader.swift`: Async asset property loading
- `NoiseClear/Services/FFmpegDenoiser.swift`: Offline file denoise and export
- `NoiseClear/Services/AudioFileService.swift`: File IO, duration, waveform-related helpers
- `NoiseClear/Services/RNNoiseProcessor.swift`: RNNoise frame processing adapter

## Fast Search Hints

- Home / navigation:
  `rg -n "FeatureItem|navigationDestination|SettingsDrawerView" NoiseClear`
- Player / streaming:
  `rg -n "loadFromURL|prepareRemoteStream|streamStatusText|fallbackReason|denoiseStrength|seek" NoiseClear`
- Batch conversion:
  `rg -n "processAll|stopProcessing|exportFile|importTask|waveform" NoiseClear`
- Localization:
  `rg -n "L10nKey|L10n\\.text|L10n\\.string|selectedLanguage|supportedLanguageCodes" NoiseClear`
