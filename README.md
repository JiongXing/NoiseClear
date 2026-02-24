# VoiceClear

> 基于 RNNoise 神经网络的音视频人声降噪工具，支持 macOS 和 iOS 双平台。

VoiceClear 是一款原生 Apple 平台应用，使用 **RNNoise**（Recurrent Neural Network Noise Suppression）C 库直接对音频和视频文件进行智能降噪。它能够在有效去除背景噪声的同时，最大程度地保留人声质量，适用于会议录音、课堂录音、播客后期、Vlog 配音等场景。

## 功能特性

- **音频降噪** — 支持 MP3、M4A、WAV、AAC、AIFF、FLAC 格式
- **视频降噪** — 支持 MP4、MOV 格式，视频流直接复制不重编码，仅降噪音频轨道
- **真流式播放降噪** — AVFoundation 增量解码 + RNNoise 小帧处理，降低首帧等待
- **在线 URL 播放** — 支持 HTTP/HTTPS MP3/MP4 在线播放，优先流式降噪，失败自动回退
- **可调节降噪强度** — 10% ~ 100% 自由调节，平衡降噪效果与人声保留
- **波形可视化** — 实时显示原始与降噪后的音频波形对比，直观感受降噪效果
- **降噪率指标** — 基于 RMS 能量计算并显示噪声缩减百分比
- **批量处理** — 一次导入多个文件，一键批量降噪与导出
- **拖拽导入** — 支持拖拽文件到窗口，也可点击选择文件
- **实时进度** — 单文件进度条 + 整体进度指示

## 技术栈

| 分类 | 技术 |
|------|------|
| 平台 | macOS / iOS (SwiftUI) |
| 语言 | Swift 5 |
| 架构 | MVVM |
| 降噪引擎 | RNNoise C 库（xiph/rnnoise，编译进二进制） |
| 音频处理 | AVFoundation (AVAudioFile / AVAudioConverter / AVAssetReader / AVAssetWriter) |
| 并发模型 | Swift Concurrency (async/await) + GCD |
| 状态管理 | @Observable (Observation 框架) |

## 真流式播放架构（AVFoundation）

实时播放链路使用统一流式协议，通过两类实现互为主备：

- `IncrementalStreamingDenoiser`（默认）  
  - 增量解码小块 PCM（本地文件 / 视频音轨）
  - RNNoise 按 480 采样点帧持续处理
  - 处理结果进入队列，`AudioEnginePlayer` 连续调度播放
- `StreamingDenoiser`（回退）  
  - 保留原有分段预处理实现，用于兼容和快速回退

在线 URL 使用 `AVPlayerItem` 路径：

- 优先 `AudioTap + RNNoise` 实时处理（真流式）
- 若不支持或挂载失败，自动降级为在线原声播放
- 若在线路径不可用，再回退到“下载后本地播放”链路

### 关键可观测指标

- 首帧时间（ms）
- 流式链路状态（本地流式 / 在线流式 / 回退模式）
- 回退原因（Tap 不可用、在线初始化失败等）

建议上线门槛：

- 常见设备下首帧时间 < 800ms
- 连续播放 10 分钟无明显卡顿/掉音
- 在线路径失败时回退成功率接近 100%

## 项目结构

```
VoiceClear/
├── VoiceClearApp.swift            # 应用入口
├── ContentView.swift              # 主界面（布局与交互编排）
├── Models/
│   └── AudioFileItem.swift        # 媒体文件数据模型 & 处理状态机
├── ViewModels/
│   └── AudioViewModel.swift       # 核心 ViewModel — 文件管理与降噪流程控制
├── Services/
│   ├── AudioFileService.swift     # 文件 I/O、格式转换、波形提取
│   ├── FFmpegDenoiser.swift       # AVFoundation + RNNoise 批处理降噪引擎
│   ├── StreamingDenoiser.swift    # AVFoundation + RNNoise 流式降噪引擎
│   └── RNNoiseProcessor.swift     # RNNoise C 库 Swift 封装
└── Views/
    ├── DropZoneView.swift         # 拖拽/选择文件区域
    ├── FileListView.swift         # 文件列表与状态展示
    └── WaveformView.swift         # 波形可视化 & 降噪前后对比
```

## 架构设计

### MVVM 分层

```
┌─────────────────────────────────────────────────┐
│                     Views                        │
│  ContentView / DropZoneView / FileListView /     │
│  WaveformView / WaveformComparisonView           │
└─────────────────────┬───────────────────────────┘
                      │ @Observable 绑定
┌─────────────────────▼───────────────────────────┐
│                  ViewModel                       │
│              AudioViewModel                      │
│  · 文件列表管理 · 降噪流程调度 · 状态与进度追踪     │
└──────────┬──────────────────────┬────────────────┘
           │                      │
┌──────────▼──────────┐ ┌────────▼─────────────────┐
│  AudioFileService   │ │   FFmpegDenoiser         │
│  · 文件选择 (面板)   │ │   · AVFoundation 解码     │
│  · 媒体时长读取      │ │   · RNNoise 降噪处理      │
│  · 音频加载/重采样   │ │   · AVAssetWriter 重封装  │
│  · 视频音频轨提取    │ │   · 进度回调              │
│  · 波形数据提取      │ └──────────────────────────┘
│  · 文件导出          │
└─────────────────────┘
```

### 状态机

文件处理采用有限状态机管理，状态流转清晰可控：

```
  ┌──────┐   开始处理   ┌────────────┐   成功   ┌───────────┐
  │ idle │────────────▶│ processing │────────▶│ completed │
  └──────┘             └────────────┘         └───────────┘
      ▲                      │
      │        失败           ▼
      │                ┌──────────┐
      └────重试────────│  failed  │
                       └──────────┘
```

- **idle** — 等待处理
- **processing(Double)** — 处理中，携带进度值 (0.0 ~ 1.0)
- **completed(URL)** — 已完成，携带临时输出文件 URL
- **failed(String)** — 失败，携带错误描述

## 降噪原理

### RNNoise

[RNNoise](https://jmvalin.ca/demo/rnnoise/) 是一个基于循环神经网络（RNN）的实时语音降噪算法，由 Mozilla/Xiph.org 开发。它专门针对人声进行训练，能够区分人声与环境噪声（如风扇声、键盘声、空调声等），在抑制噪声的同时最大程度保留语音清晰度。

### 处理流程

**音频文件：**

```
输入文件 (MP3/WAV/M4A/...)
    │
    ▼
AVAudioFile 解码
    │ 重采样至 48kHz 单声道
    ▼
RNNoise 逐帧降噪 (480 采样点/帧)
    │ 降采样至 16kHz 单声道
    ▼
输出 WAV (16kHz Mono Float32)
```

**视频文件：**

```
输入视频 (MP4/MOV)
    │
    ▼
AVAssetReader
    ├─ 视频轨: outputSettings=nil (压缩数据直通)
    │
    └─ 音频轨: 解码为 48kHz Mono PCM
               → RNNoise 降噪
    │
    ▼
AVAssetWriter
    ├─ 视频: 直通写入 (不重编码)
    └─ 音频: 编码为 AAC 192kbps
    │
    ▼
输出视频 (原格式，音频已降噪)
```

> 视频处理采用 **视频流直通**（passthrough）策略：视频流通过 `AVAssetReaderTrackOutput(outputSettings: nil)` 读取压缩数据，再通过 `AVAssetWriterInput(outputSettings: nil)` 原样写入。视频画质无损且处理速度极快。

### 波形可视化

波形显示采用 **dB 对数刻度归一化**，更符合人耳听感：

1. 音频数据按 RMS（均方根）降采样为 200 个采样点
2. 线性 RMS 值通过 `20 × log10(value / reference)` 转换为 dB 值
3. 在 -60dB ~ 0dB 范围内线性映射到 0 ~ 1
4. 使用二次贝塞尔曲线平滑连接各采样点（中点平滑算法）
5. 上下对称镜像包络 + 渐变填充，呈现专业级波形效果

降噪前后对比视图使用**统一归一化基准**（原始波形最大振幅），确保两组波形在相同刻度下可视化比较。

## 构建与运行

### 环境要求

- macOS 15.0+ / iOS 18.0+
- Xcode 16.0+
- Swift 5

### 构建步骤

1. 克隆仓库

```bash
git clone https://github.com/your-username/VoiceClear.git
cd VoiceClear
```

2. 用 Xcode 打开 `VoiceClear.xcodeproj`
3. 选择目标设备为 **My Mac** 或 iOS 设备，点击 Run

> RNNoise 模型已编译进 C 库源码（`Libraries/RNNoise/src/rnnoise_data.c`），无需额外下载模型文件。

## 使用方式

1. **导入文件** — 将音频/视频文件拖拽到窗口，或点击选择区域手动选取
2. **调节强度** — 通过底部滑块设置降噪强度（默认 80%）
3. **开始降噪** — 点击「开始降噪」按钮，处理进度实时显示
4. **预览效果** — 选中文件查看波形对比与降噪率
5. **导出文件** — 逐个导出或一键「全部导出」

## 设计亮点

| 设计决策 | 说明 |
|---------|------|
| 临时文件策略 | 降噪输出先存到系统临时目录，用户确认后才导出到指定位置，避免意外覆盖原文件 |
| 视频流直通 | 视频处理仅重编码音频，视频流通过 AVAssetWriter 直接复制，画质无损且速度极快 |
| 跨平台统一 | macOS 和 iOS 共享同一套 AVFoundation + RNNoise 降噪实现，无条件编译分支 |
| MainActor 隔离 | ViewModel 使用 `@MainActor` 标注，确保所有 UI 状态更新在主线程执行 |
| Sendable 并发安全 | FFmpegDenoiser 标记 `Sendable`，可安全在并发上下文中传递 |
| GCD + async/await | 降噪处理在后台队列执行，通过 `withCheckedThrowingContinuation` 桥接 async/await |
| 结构化错误处理 | Service 层定义独立的 `LocalizedError` 枚举，提供用户友好的错误描述 |
| dB 对数波形 | 波形使用对数刻度而非线性刻度，更真实地反映人耳感知的音量变化 |

## 支持的文件格式

| 类型 | 格式 | 输出 |
|------|------|------|
| 音频 | MP3, M4A, WAV, AAC, AIFF, FLAC | WAV (16kHz Mono Float32) |
| 视频 | MP4, MOV | 原格式 (视频无损 + 音频 AAC 192kbps) |

## 许可证

本项目基于 [GNU General Public License v3.0](LICENSE) 开源。
