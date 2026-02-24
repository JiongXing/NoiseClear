# VoiceClear 技术方案说明

## 目标

- 在 Apple 平台实现高可用音视频降噪
- 兼顾实时性（低首帧延迟）与稳定性（可回退）
- 尽量复用 AVFoundation，避免额外第三方媒体栈复杂度

## 总体架构

项目采用两条主业务线：

- 批处理线：文件导入 -> 离线降噪 -> 导出
- 播放线：本地/在线输入 -> 真流式降噪播放 -> 指标观测

关键模块：

- `PlayerViewModel`：实时播放状态机和回退控制中心
- `StreamingAudioPipeline`：统一流式音频读取协议
- `IncrementalStreamingDenoiser`：本地主播放降噪实现
- `AVPlayerDenoiseTapProcessor`：在线 URL 实时降噪处理
- `AudioEnginePlayer`：AVAudioEngine 播放与调度
- `AVAssetAsyncLoader`：iOS 16+ 异步元数据/轨道加载适配层

## 关键路径设计

### 本地媒体播放（默认）

1. `PlayerViewModel.play()` 选择本地流式路径
2. `IncrementalStreamingDenoiser` 增量解码 PCM
3. RNNoise 按 480 样本帧处理
4. `AudioEnginePlayer` 持续调度播放

特点：

- 首帧快（小批量预缓冲）
- 内存峰值可控（增量处理而非整段处理）
- 可切换回 legacy `StreamingDenoiser`

### 在线媒体播放（优先）

1. `AVPlayerItem` 建立在线播放链路
2. `MTAudioProcessingTap` 注入音轨处理
3. Tap 回调中执行 RNNoise
4. 失败时自动降级（在线原声/下载后本地）

特点：

- 真流式在线降噪
- 平滑回退策略，优先保证可播放

## 回退策略

按优先级从上到下：

1. 在线 AudioTap 降噪播放
2. 在线原声播放
3. 下载后本地播放

触发条件示例：

- Tap 创建或挂载失败
- 在线流初始化失败
- 特定媒体源兼容性问题

## 并发与线程安全策略

- ViewModel 使用 `@MainActor` 保证 UI 状态一致性
- 后台读取循环使用线程安全控制器（锁保护）
- 流式管线对象显式处理 `Sendable` 兼容
- 避免在异步上下文使用阻塞 API（如 `Thread.sleep`）

## 性能与稳定性指标

建议持续监控以下指标：

- 首帧时间（ms）
- 缓冲时长与卡顿次数
- 回退触发率及原因分布
- 连续播放稳定性（长时无掉音）

建议门槛：

- 首帧时间 < 800ms（常见设备）
- 在线回退链路成功率接近 100%

## 未来演进建议

- 增加策略开关（强制 incremental/legacy）用于 A/B 验证
- 增加链路级日志上报（首帧、回退、卡顿事件）
- 细化在线流源兼容矩阵（编码格式、容器、码率）
