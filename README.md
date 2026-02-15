# VoiceClean

> 基于 RNNoise 神经网络的音视频人声降噪工具，专为 macOS 打造。

VoiceClean 是一款原生 macOS 应用，使用 FFmpeg 内置的 **arnndn**（Audio Recurrent Neural Network Denoiser）滤镜对音频和视频文件进行智能降噪。它能够在有效去除背景噪声的同时，最大程度地保留人声质量，适用于会议录音、课堂录音、播客后期、Vlog 配音等场景。

## 功能特性

- **音频降噪** — 支持 MP3、M4A、WAV、AAC、AIFF、FLAC 格式
- **视频降噪** — 支持 MP4、MOV 格式，视频流直接复制不重编码，仅降噪音频轨道
- **可调节降噪强度** — 10% ~ 100% 自由调节，平衡降噪效果与人声保留
- **波形可视化** — 实时显示原始与降噪后的音频波形对比，直观感受降噪效果
- **降噪率指标** — 基于 RMS 能量计算并显示噪声缩减百分比
- **批量处理** — 一次导入多个文件，一键批量降噪与导出
- **拖拽导入** — 支持拖拽文件到窗口，也可点击选择文件
- **实时进度** — 单文件进度条 + 整体进度指示

## 技术栈

| 分类 | 技术 |
|------|------|
| 平台 | macOS (SwiftUI) |
| 语言 | Swift 5 |
| 架构 | MVVM |
| 降噪引擎 | FFmpeg arnndn 滤镜 (RNNoise 神经网络) |
| 音频处理 | AVFoundation (AVAudioFile / AVAudioConverter) |
| 并发模型 | Swift Concurrency (async/await) + GCD |
| 状态管理 | @Observable (Observation 框架) |

## 项目结构

```
VoiceClean/
├── VoiceCleanApp.swift            # 应用入口
├── ContentView.swift              # 主界面（布局与交互编排）
├── Models/
│   └── AudioFileItem.swift        # 媒体文件数据模型 & 处理状态机
├── ViewModels/
│   └── AudioViewModel.swift       # 核心 ViewModel — 文件管理与降噪流程控制
├── Services/
│   ├── AudioFileService.swift     # 文件 I/O、格式转换、波形提取
│   └── FFmpegDenoiser.swift       # FFmpeg 进程管理与降噪执行
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
│  · 文件选择 (面板)   │ │   · FFmpeg 进程封装       │
│  · 媒体时长读取      │ │   · arnndn 滤镜参数构建   │
│  · 音频加载/重采样   │ │   · 进度解析              │
│  · 视频音频轨提取    │ │   · 错误处理              │
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
FFmpeg Process
    │ -af "arnndn=m=std.rnnn:mix=X"
    │ -ar 16000 -ac 1 -c:a pcm_f32le
    ▼
输出 WAV (16kHz Mono Float32)
```

**视频文件：**

```
输入视频 (MP4/MOV)
    │
    ▼
FFmpeg Process
    ├─ 视频流: -c:v copy (直接复制，不重编码)
    │
    └─ 音频流: -af "arnndn=m=std.rnnn:mix=X"
               -c:a aac -b:a 192k
    │
    ▼
输出视频 (原格式，音频已降噪)
```

> 视频处理采用 **视频流直通**（passthrough）策略：视频流原样复制，仅重新编码音频轨道。这意味着视频画质无损且处理速度极快。

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

- macOS 15.0+
- Xcode 16.0+
- Swift 5

### 准备资源文件

项目运行需要以下两个资源文件，请将它们添加到 Xcode 项目的 **Resources** 目录中：

1. **`ffmpeg`** — FFmpeg 可执行文件（静态编译版本）
2. **`std.rnnn`** — RNNoise 神经网络模型文件

获取方式：

```bash
# FFmpeg 静态构建（推荐使用 Homebrew 或从官方下载）
# 确保编译时启用了 librnnoise 支持

# RNNoise 模型文件可从以下地址获取：
# https://github.com/xiph/rnnoise/tree/master/model
```

### 构建步骤

1. 克隆仓库

```bash
git clone https://github.com/your-username/VoiceClean.git
cd VoiceClean
```

2. 将 `ffmpeg` 可执行文件和 `std.rnnn` 模型文件放入项目 Resources 目录
3. 用 Xcode 打开 `VoiceClean.xcodeproj`
4. 选择目标设备为 **My Mac**，点击 Run

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
| 视频流直通 | 视频处理仅重编码音频，视频流 `-c:v copy` 直接复制，画质无损且速度极快 |
| MainActor 隔离 | ViewModel 使用 `@MainActor` 标注，确保所有 UI 状态更新在主线程执行 |
| Sendable 并发安全 | FFmpegDenoiser 标记 `Sendable`，可安全在并发上下文中传递 |
| GCD + async/await | FFmpeg 进程在后台队列执行，通过 `withCheckedThrowingContinuation` 桥接 async/await |
| 结构化错误处理 | Service 层定义独立的 `LocalizedError` 枚举，提供用户友好的错误描述 |
| dB 对数波形 | 波形使用对数刻度而非线性刻度，更真实地反映人耳感知的音量变化 |

## 支持的文件格式

| 类型 | 格式 | 输出 |
|------|------|------|
| 音频 | MP3, M4A, WAV, AAC, AIFF, FLAC | WAV (16kHz Mono Float32) |
| 视频 | MP4, MOV | 原格式 (视频无损 + 音频 AAC 192kbps) |

## 许可证

MIT License
