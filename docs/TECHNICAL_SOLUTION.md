# VoiceClear 技术方案说明

## 方案定位

VoiceClear 当前播放能力采用双链路实时降噪架构：

- **本地链路**：`IncrementalStreamingDenoiser` + `AudioEnginePlayer`
- **在线链路**：`AVPlayerItem` + `MTAudioProcessingTap` + `AVPlayerDenoiseTapProcessor`

核心目标是同时满足：

- 低启动延迟（Streaming First Frame）
- 长时播放稳定性（不卡顿、不断播）
- 音频连续性（降低重音、拖音、爆破音）

## 播放控制中枢

`PlayerViewModel` 统一管理播放状态机、链路选择和回退：

- 本地输入走 `localEngine` 路径，在线 URL 走 `remoteAVPlayer` 路径
- 使用 `activePlaybackToken` 保护异步播放请求，避免 `play/pause/seek` 竞争导致状态反复
- 通过 `PlaybackMetrics` 记录首帧耗时和回退原因
- 页面退出时触发 `stop()`，确保音频链路及时释放

## 本地流式降噪链路

### 在线处理流程

1. `IncrementalStreamingDenoiser` 按小块增量读取输入媒体
2. 统一转换到目标采样格式（降噪为单声道 48k）
3. 以 RNNoise 帧长（480 samples）执行逐帧降噪
4. 转为双声道输出并进入 `AudioEnginePlayer` 调度

### 连续性策略

- 在降噪块拼接处维护 `previousDenoisedTail`
- 当相邻块边界跳变超过阈值时，对开头片段执行短淡入平滑（fade）
- 目标是抑制语音瞬态中的爆破感和轻微边界失真

### 缓冲策略

- 管线内部队列上限约 2 秒（`maxQueuedFrames`）
- 播放前执行小预缓冲（音频约 0.2s，视频约 0.35s）
- 后台读取循环按缓冲水位持续填充

## 在线实时降噪链路

### 处理流程

1. `AVPlayerItem` 建立在线播放
2. `MTAudioProcessingTap` 挂载音轨处理回调
3. 回调中统一为 mono，执行 RNNoise，再写回多声道
4. `AVPlayer` 直接输出（不经过本地 `AudioEnginePlayer`）

### 采样率与连续性策略

在线流源采样率可能与 RNNoise 固定采样率不一致，当前实现使用双向转换：

- `toRNConverter`：源采样率 -> RNNoise 采样率
- `fromRNConverter`：RNNoise 采样率 -> 源采样率

为避免“每包独立重映射”带来的拖音/重音，现实现采用：

- `rnPendingSamples`：保持 RNNoise 帧对齐，跨回调累计后再处理
- `sourcePendingSamples`：重采样后样本跨回调连续消费，按输入帧数出样
- `applyBoundarySmoothingIfNeeded`：回调边界平滑，降低包间突变

该模型本质是“连续样本流”而非“独立包处理”，可显著改善在线链路的时间轴稳定性。

## 回退与可用性策略

在线 URL 路径按可用性逐级回退：

1. 在线 AudioTap 降噪播放
2. 在线原声播放（Tap 不可用或挂载失败）
3. 下载到本地后播放（远端初始化失败）

回退原因会写入 `fallbackReason`，用于质量分析与后续优化。

## 并发与线程模型

- `PlayerViewModel` 运行在 `@MainActor`，保证 UI 状态一致
- 本地读取循环由独立 `DispatchQueue` 驱动
- `ReadLoopController` 通过锁保护运行状态
- 管线实现按 `Sendable` 约束组织，降低并发读写风险

## 质量指标

建议以以下指标持续评估版本质量：

- 首帧延迟（`startupLatencyMs`）
- 回退率及回退原因分布
- 长时播放稳定性（结束判定正确、无异常中断）
- 音频连续性主观指标（重音、拖音、爆破音）

## 后续优化方向

- 将本地读取循环从 sleep 轮询演进为事件驱动，降低空转开销
- 细化在线流兼容矩阵（编码、采样率、声道布局）
- 对边界平滑阈值与窗口长度做参数化，支持设备与内容自适应
