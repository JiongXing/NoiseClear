//
//  FFmpegDenoiser.swift
//  VoiceClear
//
//  Created by jxing on 2026/2/14.
//

import Accelerate
import AVFoundation
import CoreMedia
import Foundation

// MARK: - 降噪引擎

/// 基于 RNNoise 神经网络的音频降噪引擎（跨平台统一实现）
///
/// RNNoise 专门针对人声进行降噪，能有效去除背景噪声同时保留语音质量。
/// 使用 AVFoundation 进行音频解码/编码，RNNoise C 库执行降噪算法。
///
/// - 纯音频: AVAudioFile 解码 → RNNoise 降噪 → AVAudioFile 写入 WAV (16kHz)
/// - 视频: AVAssetReader 解码 → RNNoise 降噪音频 → AVAssetWriter 重封装（视频直通 + AAC 音频）
final class FFmpegDenoiser: Sendable {

    // MARK: - 常量

    /// 输出音频采样率 (Hz)，仅用于纯音频降噪输出
    static let outputSampleRate: Double = 16000.0

    // MARK: - 属性

    /// 降噪强度 (0.0 ~ 1.0)
    private let denoiseStrength: Float

    // MARK: - 初始化

    /// 初始化降噪引擎
    /// - Parameter strength: 降噪强度 (0.0 ~ 1.0)，默认 1.0（全强度）
    init(strength: Float = 1.0) {
        self.denoiseStrength = max(0.0, min(1.0, strength))
    }

    // MARK: - 主处理方法

    /// 对音频或视频文件执行降噪处理
    ///
    /// - 音频文件：输出降噪后的 16kHz 单声道 WAV
    /// - 视频文件：视频流直通 + 音频轨道降噪后重新编码为 AAC，输出原格式 (MP4/MOV)
    ///
    /// - Parameters:
    ///   - inputURL: 输入文件 URL（音频或视频）
    ///   - outputURL: 输出文件 URL（音频→WAV，视频→原格式）
    ///   - duration: 媒体总时长（秒），用于计算进度
    ///   - isVideo: 是否为视频文件（视频模式下保留视频流，仅降噪音频轨道）
    ///   - onProgress: 进度回调 (0.0 ~ 1.0)
    func process(
        inputURL: URL,
        outputURL: URL,
        duration: TimeInterval,
        isVideo: Bool = false,
        onProgress: @escaping @Sendable (Double) -> Void
    ) throws {
        if isVideo {
            try denoiseVideo(
                inputURL: inputURL,
                outputURL: outputURL,
                duration: duration,
                onProgress: onProgress
            )
        } else {
            try denoiseAudio(
                inputURL: inputURL,
                outputURL: outputURL,
                duration: duration,
                onProgress: onProgress
            )
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw FFmpegDenoiserError.outputFileMissing
        }
    }

    // MARK: - 纯音频降噪

    /// 使用 AVFoundation + RNNoise 对纯音频文件降噪
    ///
    /// 流程: AVAudioFile 解码 → 重采样 48kHz 单声道 → RNNoise 逐帧降噪 → 降采样 16kHz → 写入 WAV
    private func denoiseAudio(
        inputURL: URL,
        outputURL: URL,
        duration: TimeInterval,
        onProgress: @escaping @Sendable (Double) -> Void
    ) throws {
        // 1. 读取源文件
        let sourceFile = try AVAudioFile(forReading: inputURL)
        let sourceFormat = sourceFile.processingFormat
        let sourceFrameCount = AVAudioFrameCount(sourceFile.length)

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceFrameCount) else {
            throw FFmpegDenoiserError.processingFailed("无法创建源音频缓冲区")
        }
        try sourceFile.read(into: sourceBuffer)
        onProgress(0.02)

        // 2. 转换为 48kHz 单声道（RNNoise 要求）
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: RNNoiseProcessor.sampleRate,
            channels: 1,
            interleaved: false
        )!

        guard let converter = AVAudioConverter(from: sourceFormat, to: monoFormat) else {
            throw FFmpegDenoiserError.processingFailed("无法创建格式转换器")
        }

        let ratio = RNNoiseProcessor.sampleRate / sourceFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(sourceFrameCount) * ratio) + 256
        guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: outCapacity) else {
            throw FFmpegDenoiserError.processingFailed("无法创建单声道缓冲区")
        }

        var isDone = false
        var convError: NSError?
        converter.convert(to: monoBuffer, error: &convError) { _, outStatus in
            if isDone {
                outStatus.pointee = .noDataNow
                return nil
            }
            isDone = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        if let convError { throw FFmpegDenoiserError.processingFailed(convError.localizedDescription) }
        onProgress(0.05)

        // 3. RNNoise 逐帧降噪
        guard let monoData = monoBuffer.floatChannelData?[0] else {
            throw FFmpegDenoiserError.processingFailed("无法读取单声道数据")
        }
        let sampleCount = Int(monoBuffer.frameLength)
        let denoisedSamples = try denoiseRawSamples(
            monoData, count: sampleCount, strength: denoiseStrength
        ) { denoiseProgress in
            onProgress(0.05 + denoiseProgress * 0.90)
        }

        // 4. 降采样到输出采样率（16kHz）并写入
        guard let denoisedBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(sampleCount)) else {
            throw FFmpegDenoiserError.processingFailed("无法创建降噪缓冲区")
        }
        denoisedBuffer.frameLength = AVAudioFrameCount(sampleCount)
        denoisedSamples.withUnsafeBufferPointer { src in
            denoisedBuffer.floatChannelData![0].update(from: src.baseAddress!, count: sampleCount)
        }

        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.outputSampleRate,
            channels: 1,
            interleaved: false
        )!

        guard let outConverter = AVAudioConverter(from: monoFormat, to: outputFormat) else {
            throw FFmpegDenoiserError.processingFailed("无法创建输出格式转换器")
        }

        let outRatio = Self.outputSampleRate / RNNoiseProcessor.sampleRate
        let finalCapacity = AVAudioFrameCount(Double(sampleCount) * outRatio) + 256
        guard let finalBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: finalCapacity) else {
            throw FFmpegDenoiserError.processingFailed("无法创建输出缓冲区")
        }

        var outDone = false
        var outConvError: NSError?
        outConverter.convert(to: finalBuffer, error: &outConvError) { _, outStatus in
            if outDone {
                outStatus.pointee = .noDataNow
                return nil
            }
            outDone = true
            outStatus.pointee = .haveData
            return denoisedBuffer
        }
        if let outConvError { throw FFmpegDenoiserError.processingFailed(outConvError.localizedDescription) }

        let outputFile = try AVAudioFile(forWriting: outputURL, settings: outputFormat.settings)
        try outputFile.write(from: finalBuffer)

        onProgress(1.0)
    }

    // MARK: - 视频降噪（视频直通 + 音频降噪重封装）

    /// 对视频文件执行降噪：视频流直通复制 + 音频轨道降噪后重新编码
    ///
    /// 流程:
    /// 1. AVAssetReader 读取音频 PCM 并收集全部样本
    /// 2. RNNoise 降噪处理
    /// 3. AVAssetReader (视频直通) + AVAssetWriter (视频直通 + AAC 音频) 重封装
    private func denoiseVideo(
        inputURL: URL,
        outputURL: URL,
        duration: TimeInterval,
        onProgress: @escaping @Sendable (Double) -> Void
    ) throws {
        let asset = AVURLAsset(url: inputURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw FFmpegDenoiserError.noVideoTrack
        }
        guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
            throw FFmpegDenoiserError.noAudioTrack
        }

        // --- Phase 1: 读取并降噪音频 ---

        let audioReader = try AVAssetReader(asset: asset)
        let audioReaderOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: RNNoiseProcessor.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        audioReaderOutput.alwaysCopiesSampleData = false
        audioReader.add(audioReaderOutput)

        guard audioReader.startReading() else {
            throw FFmpegDenoiserError.processingFailed(
                audioReader.error?.localizedDescription ?? "音频读取启动失败"
            )
        }

        var allSamples = [Float]()
        while audioReader.status == .reading {
            guard let sampleBuffer = audioReaderOutput.copyNextSampleBuffer() else { break }
            let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
            guard numSamples > 0 else { continue }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
            guard let data = dataPointer else { continue }

            let floatCount = totalLength / MemoryLayout<Float>.size
            let floatPtr = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: floatCount)
            allSamples.append(contentsOf: UnsafeBufferPointer(start: floatPtr, count: floatCount))
        }
        onProgress(0.03)

        guard !allSamples.isEmpty else {
            throw FFmpegDenoiserError.processingFailed("视频音频轨道无有效数据")
        }

        // RNNoise 降噪
        let denoisedSamples: [Float] = try allSamples.withUnsafeBufferPointer { ptr in
            try denoiseRawSamples(
                ptr.baseAddress!, count: allSamples.count, strength: denoiseStrength
            ) { denoiseProgress in
                onProgress(0.03 + denoiseProgress * 0.89)
            }
        }
        onProgress(0.92)

        // --- Phase 2: 视频直通 + 降噪音频 重封装 ---

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let videoReader = try AVAssetReader(asset: asset)
        let videoReaderOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoReader.add(videoReaderOutput)

        guard videoReader.startReading() else {
            throw FFmpegDenoiserError.processingFailed(
                videoReader.error?.localizedDescription ?? "视频读取启动失败"
            )
        }

        let fileType: AVFileType = outputURL.pathExtension.lowercased() == "mov" ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)

        // 视频输入：直通写入（不重编码，速度极快）
        // MP4 直通模式要求提供 sourceFormatHint，否则 AVAssetWriter 会抛出异常
        var videoFormatHint: CMFormatDescription?
        if let firstDesc = videoTrack.formatDescriptions.first {
            videoFormatHint = (firstDesc as! CMFormatDescription)
        }

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: videoFormatHint
        )
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        // 音频输入：编码为 AAC 192kbps
        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: RNNoiseProcessor.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 192_000
            ]
        )
        audioInput.expectsMediaDataInRealTime = false
        writer.add(audioInput)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        // 使用 Sendable 友好的方式传递错误
        let errorHolder = ErrorHolder()

        // 视频直通写入
        group.enter()
        let videoQueue = DispatchQueue(label: "com.voiceclear.denoise.video", qos: .userInitiated)
        videoInput.requestMediaDataWhenReady(on: videoQueue) { [videoReader, videoReaderOutput] in
            while videoInput.isReadyForMoreMediaData {
                if videoReader.status == .reading,
                   let sample = videoReaderOutput.copyNextSampleBuffer() {
                    videoInput.append(sample)
                } else {
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
            }
        }

        // 降噪音频写入
        group.enter()
        let audioQueue = DispatchQueue(label: "com.voiceclear.denoise.audio", qos: .userInitiated)
        nonisolated(unsafe) var audioWriteOffset = 0
        let totalAudioSamples = denoisedSamples.count
        let audioChunkSize = 4096

        audioInput.requestMediaDataWhenReady(on: audioQueue) {
            while audioInput.isReadyForMoreMediaData {
                guard audioWriteOffset < totalAudioSamples else {
                    audioInput.markAsFinished()
                    group.leave()
                    return
                }

                let remaining = totalAudioSamples - audioWriteOffset
                let chunkSize = min(audioChunkSize, remaining)
                let pts = CMTime(
                    value: CMTimeValue(audioWriteOffset),
                    timescale: CMTimeScale(RNNoiseProcessor.sampleRate)
                )

                if let sampleBuffer = Self.createPCMAudioSampleBuffer(
                    from: denoisedSamples,
                    offset: audioWriteOffset,
                    count: chunkSize,
                    sampleRate: RNNoiseProcessor.sampleRate,
                    presentationTime: pts
                ) {
                    if !audioInput.append(sampleBuffer) {
                        errorHolder.error = writer.error
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                }

                audioWriteOffset += chunkSize
            }
        }

        group.wait()

        if let writerError = errorHolder.error {
            writer.cancelWriting()
            throw FFmpegDenoiserError.writerFailed(writerError.localizedDescription)
        }

        // 完成写入
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()


        guard writer.status == .completed else {
            throw FFmpegDenoiserError.writerFailed(
                writer.error?.localizedDescription ?? "视频写入完成状态异常"
            )
        }

        onProgress(1.0)
    }

    // MARK: - RNNoise 降噪核心

    /// 对原始 PCM 样本执行 RNNoise 降噪
    ///
    /// RNNoise 期望输入范围为 -32768~32768（int16 浮点表示），
    /// 因此需要先缩放再处理，处理后缩放回 -1.0~1.0 范围。
    ///
    /// - Parameters:
    ///   - samples: 输入 PCM 数据指针（48kHz 单声道 Float32，范围 -1.0~1.0）
    ///   - count: 样本数量
    ///   - strength: 降噪强度 (0.0 ~ 1.0)
    ///   - onProgress: 降噪进度回调 (0.0 ~ 1.0)
    /// - Returns: 降噪后的 PCM 数据
    private func denoiseRawSamples(
        _ samples: UnsafePointer<Float>,
        count: Int,
        strength: Float,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) throws -> [Float] {
        let processor = try RNNoiseProcessor()
        defer { processor.close() }

        let frameSize = RNNoiseProcessor.frameSize
        var scaleFactor: Float = 32768.0
        var invScaleFactor: Float = 1.0 / 32768.0
        var result = [Float](repeating: 0, count: count)
        var offset = 0

        // 预分配帧缓冲区，避免每帧重复分配（90 分钟约 54 万次分配 → 0 次）
        var inputFrame = [Float](repeating: 0, count: frameSize)
        var outputFrame = [Float](repeating: 0, count: frameSize)

        // 进度回调节流：每前进约 1% 才回调一次，避免 54 万次回调导致的性能损耗
        var lastReportedProgress: Double = -1

        while offset < count {
            let remaining = count - offset
            let currentSize = min(frameSize, remaining)

            // 使用 vDSP 加速缩放（替代手动 for 循环）
            vDSP_vsmul(samples + offset, 1, &scaleFactor, &inputFrame, 1, vDSP_Length(currentSize))
            if currentSize < frameSize {
                for i in currentSize..<frameSize { inputFrame[i] = 0 }
            }

            processor.processFrame(output: &outputFrame, input: &inputFrame)

            // 输出：反缩放 + 可选混合（使用 vDSP 加速）
            if strength >= 1.0 {
                vDSP_vsmul(outputFrame, 1, &invScaleFactor, &result[offset], 1, vDSP_Length(currentSize))
            } else {
                // 复用 inputFrame 存放缩放后的降噪结果，再用 vDSP_vintb 做线性插值
                vDSP_vsmul(outputFrame, 1, &invScaleFactor, &inputFrame, 1, vDSP_Length(currentSize))
                var strengthVar = strength
                vDSP_vintb(samples + offset, 1, &inputFrame, 1, &strengthVar, &result[offset], 1, vDSP_Length(currentSize))
            }

            offset += frameSize

            // 节流后的进度回调：每 1% 或结束时回调
            let progress = Double(offset) / Double(count)
            if let cb = onProgress, progress - lastReportedProgress >= 0.01 || progress >= 1.0 {
                lastReportedProgress = progress
                cb(progress)
            }
        }

        return result
    }

    // MARK: - CMSampleBuffer 创建辅助

    /// 从 Float32 PCM 数组创建 CMSampleBuffer（用于 AVAssetWriter 音频写入）
    private static func createPCMAudioSampleBuffer(
        from samples: [Float],
        offset: Int,
        count: Int,
        sampleRate: Double,
        presentationTime: CMTime
    ) -> CMSampleBuffer? {
        let bytesPerSample = MemoryLayout<Float>.size
        let dataSize = count * bytesPerSample

        // 创建 CMBlockBuffer 并分配内存
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        // 拷贝 PCM 数据到 block buffer
        samples.withUnsafeBufferPointer { ptr in
            let src = UnsafeRawPointer(ptr.baseAddress!.advanced(by: offset))
            status = CMBlockBufferReplaceDataBytes(
                with: src,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: dataSize
            )
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        // 创建音频格式描述（交错 Float32 单声道）
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerSample),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerSample),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else { return nil }

        // 创建 CMSampleBuffer
        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: count,
            presentationTimeStamp: presentationTime,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )

        return sampleBuffer
    }
}

// MARK: - 线程安全错误容器

/// 用于在 GCD 回调中安全传递错误信息
private final class ErrorHolder: @unchecked Sendable {
    var error: Error?
}

// MARK: - 错误类型

enum FFmpegDenoiserError: LocalizedError {
    case outputFileMissing
    case processingFailed(String)
    case noVideoTrack
    case noAudioTrack
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .outputFileMissing:
            return "处理完成但输出文件不存在"
        case .processingFailed(let msg):
            return "音频处理失败: \(msg)"
        case .noVideoTrack:
            return "视频文件中未找到视频轨道"
        case .noAudioTrack:
            return "视频文件中未找到音频轨道"
        case .writerFailed(let msg):
            return "视频写入失败: \(msg)"
        }
    }
}
