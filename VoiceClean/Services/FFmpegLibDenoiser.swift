//
//  FFmpegLibDenoiser.swift
//  VoiceClean
//
//  iOS 专用：使用 FFmpeg C API (Libavfilter) 实现 arnndn 降噪
//
//  macOS 上通过 Process 启动 ffmpeg 二进制完成降噪，但 iOS 无法使用 Process。
//  本文件直接调用 FFmpeg 的 C 库 API 构建 avfilter graph，
//  实现与 macOS 端等效的 arnndn 降噪功能。
//
//  处理流程:
//    输入文件 → avformat 解封装 → avcodec 解码 →
//    avfilter (abuffersrc → arnndn → aformat → abuffersink) →
//    avcodec 编码 → avformat 封装 → 输出文件
//

#if os(iOS)

import Foundation
import Libavformat
import Libavcodec
import Libavfilter
import Libavutil
import Libswresample

// MARK: - FFmpeg C 宏的 Swift 等价定义（复杂 C 宏无法被 Swift ClangImporter 自动桥接）

/// AV_NOPTS_VALUE = ((int64_t)UINT64_C(0x8000000000000000)) = Int64.min
private let FF_AV_NOPTS_VALUE: Int64 = Int64.min

/// AVERROR_EOF = FFERRTAG('E','O','F',' ') = -(MKTAG('E','O','F',' ')) = -0x20464F45
private let FF_AVERROR_EOF: Int32 = -0x20_46_4F_45

// MARK: - 错误类型

enum FFmpegLibError: LocalizedError {
    case openInputFailed(String)
    case streamInfoFailed
    case noAudioStream
    case noVideoStream
    case decoderNotFound
    case decoderOpenFailed
    case filterGraphFailed(String)
    case outputFormatFailed
    case outputStreamFailed
    case encoderNotFound
    case encoderOpenFailed
    case writeHeaderFailed
    case processingFailed(String)
    case modelNotFound

    var errorDescription: String? {
        switch self {
        case .openInputFailed(let msg): return "无法打开输入文件: \(msg)"
        case .streamInfoFailed: return "无法读取流信息"
        case .noAudioStream: return "未找到音频流"
        case .noVideoStream: return "未找到视频流"
        case .decoderNotFound: return "找不到音频解码器"
        case .decoderOpenFailed: return "无法打开音频解码器"
        case .filterGraphFailed(let msg): return "滤镜图创建失败: \(msg)"
        case .outputFormatFailed: return "无法创建输出格式"
        case .outputStreamFailed: return "无法创建输出流"
        case .encoderNotFound: return "找不到音频编码器"
        case .encoderOpenFailed: return "无法打开音频编码器"
        case .writeHeaderFailed: return "写入文件头失败"
        case .processingFailed(let msg): return "处理失败: \(msg)"
        case .modelNotFound: return "找不到 RNNoise 模型文件 (std.rnnn)"
        }
    }
}

// MARK: - FFmpeg C API 降噪引擎

/// 使用 FFmpeg Libavfilter 的 arnndn 滤镜进行音频降噪（iOS 专用）
///
/// 如果 arnndn 滤镜不可用（取决于 FFmpegKit 构建配置），
/// 自动回退到 afftdn（FFT 降噪）滤镜。
final class FFmpegLibDenoiser: @unchecked Sendable {

    /// 检查指定的 avfilter 是否可用
    static func isFilterAvailable(_ name: String) -> Bool {
        return avfilter_get_by_name(name) != nil
    }

    /// 构建降噪滤镜描述（自动选择可用滤镜）
    ///
    /// 优先使用 arnndn（RNNoise），不可用时回退到 afftdn（FFT降噪）
    private static func buildDenoiseFilter(
        modelPath: String,
        strength: Float,
        sampleRate: Int32,
        channels: Int32
    ) -> String {
        let channelLayout = channels == 1 ? "mono" : "stereo"
        let mix = String(format: "%.2f", max(0, min(1, strength)))

        if isFilterAvailable("arnndn") {
            // 首选：RNNoise 神经网络降噪
            return "arnndn=m=\(modelPath):mix=\(mix),aformat=sample_fmts=flt:sample_rates=\(sampleRate):channel_layouts=\(channelLayout)"
        } else if isFilterAvailable("afftdn") {
            // 回退：FFT 降噪（将 strength 0~1 映射为 nr 5~40 dB）
            let nr = Int(5 + strength * 35)
            return "afftdn=nr=\(nr):nf=-25:nt=w,aformat=sample_fmts=flt:sample_rates=\(sampleRate):channel_layouts=\(channelLayout)"
        } else {
            // 无降噪滤镜可用，仅做格式转换
            return "aformat=sample_fmts=flt:sample_rates=\(sampleRate):channel_layouts=\(channelLayout)"
        }
    }

    /// 构建降噪滤镜描述（无 aformat，用于视频处理）
    private static func buildDenoiseFilterRaw(
        modelPath: String,
        strength: Float
    ) -> String {
        let mix = String(format: "%.2f", max(0, min(1, strength)))

        if isFilterAvailable("arnndn") {
            return "arnndn=m=\(modelPath):mix=\(mix)"
        } else if isFilterAvailable("afftdn") {
            let nr = Int(5 + strength * 35)
            return "afftdn=nr=\(nr):nf=-25:nt=w"
        } else {
            return "anull"
        }
    }

    // MARK: - 批量处理（音频文件 → WAV 文件）

    /// 对音频文件执行降噪，输出 WAV
    ///
    /// - Parameters:
    ///   - inputURL: 输入音频文件
    ///   - outputURL: 输出 WAV 文件
    ///   - strength: 降噪强度 (0.0 ~ 1.0)
    ///   - sampleRate: 输出采样率
    ///   - channels: 输出声道数
    ///   - duration: 媒体总时长（秒），用于计算进度
    ///   - onProgress: 进度回调 (0.0 ~ 1.0)
    static func denoiseAudio(
        inputURL: URL,
        outputURL: URL,
        strength: Float,
        sampleRate: Int32 = 16000,
        channels: Int32 = 1,
        duration: TimeInterval,
        onProgress: @escaping @Sendable (Double) -> Void
    ) throws {
        let modelPath = try getModelPath()

        let filterDesc = buildDenoiseFilter(
            modelPath: modelPath,
            strength: strength,
            sampleRate: sampleRate,
            channels: channels
        )

        try processAudioFile(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            filterDescription: filterDesc,
            outputSampleRate: sampleRate,
            outputChannels: channels,
            outputCodecID: AV_CODEC_ID_PCM_F32LE,
            outputFormatName: "wav",
            totalDuration: duration,
            onProgress: onProgress
        )
    }

    // MARK: - 批量处理（视频文件 → 视频文件，仅降噪音频轨道）

    /// 对视频文件的音频轨道执行降噪，视频流直接复制
    ///
    /// - Parameters:
    ///   - inputURL: 输入视频文件
    ///   - outputURL: 输出视频文件（与输入同格式）
    ///   - strength: 降噪强度 (0.0 ~ 1.0)
    ///   - duration: 媒体总时长（秒）
    ///   - onProgress: 进度回调
    static func denoiseVideo(
        inputURL: URL,
        outputURL: URL,
        strength: Float,
        duration: TimeInterval,
        onProgress: @escaping @Sendable (Double) -> Void
    ) throws {
        let modelPath = try getModelPath()

        let filterDesc = buildDenoiseFilterRaw(modelPath: modelPath, strength: strength)

        try processVideoFile(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            filterDescription: filterDesc,
            totalDuration: duration,
            onProgress: onProgress
        )
    }

    // MARK: - 分块处理（用于流式播放）

    /// 处理一小段音频到临时 WAV 文件（供 StreamingDenoiser 使用）
    ///
    /// - Parameters:
    ///   - inputURL: 输入媒体文件
    ///   - outputURL: 输出临时 WAV 文件
    ///   - strength: 降噪强度
    ///   - startTime: 起始时间（秒）
    ///   - maxDuration: 最大处理时长（秒）
    ///   - sampleRate: 输出采样率
    ///   - channels: 输出声道数
    ///   - isVideo: 是否为视频文件（视频时仅提取音频）
    static func denoiseChunk(
        inputURL: URL,
        outputURL: URL,
        strength: Float,
        startTime: TimeInterval = 0,
        maxDuration: TimeInterval? = nil,
        sampleRate: Int32 = 48000,
        channels: Int32 = 2,
        isVideo: Bool = false
    ) throws {
        let modelPath = try getModelPath()

        let filterDesc = buildDenoiseFilter(
            modelPath: modelPath,
            strength: strength,
            sampleRate: sampleRate,
            channels: channels
        )

        try processAudioFile(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            filterDescription: filterDesc,
            outputSampleRate: sampleRate,
            outputChannels: channels,
            outputCodecID: AV_CODEC_ID_PCM_F32LE,
            outputFormatName: "wav",
            totalDuration: maxDuration ?? 0,
            seekTo: startTime,
            maxDuration: maxDuration,
            discardVideo: isVideo,
            onProgress: { _ in }
        )
    }

    /// 处理原始音频分块（不降噪，仅格式转换）
    static func originalChunk(
        inputURL: URL,
        outputURL: URL,
        startTime: TimeInterval = 0,
        maxDuration: TimeInterval? = nil,
        sampleRate: Int32 = 48000,
        channels: Int32 = 2,
        isVideo: Bool = false
    ) throws {
        let channelLayout = channels == 1 ? "mono" : "stereo"
        let filterDesc = "aformat=sample_fmts=flt:sample_rates=\(sampleRate):channel_layouts=\(channelLayout)"

        try processAudioFile(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            filterDescription: filterDesc,
            outputSampleRate: sampleRate,
            outputChannels: channels,
            outputCodecID: AV_CODEC_ID_PCM_F32LE,
            outputFormatName: "wav",
            totalDuration: maxDuration ?? 0,
            seekTo: startTime,
            maxDuration: maxDuration,
            discardVideo: isVideo,
            onProgress: { _ in }
        )
    }

    // MARK: - 提取视频中的音频（用于波形加载）

    /// 从视频文件提取音频并输出为 WAV
    static func extractAudio(
        from videoURL: URL,
        to audioURL: URL,
        sampleRate: Int32 = 16000,
        channels: Int32 = 1
    ) throws {
        let channelLayout = channels == 1 ? "mono" : "stereo"
        let filterDesc = "aformat=sample_fmts=flt:sample_rates=\(sampleRate):channel_layouts=\(channelLayout)"

        try processAudioFile(
            inputPath: videoURL.path,
            outputPath: audioURL.path,
            filterDescription: filterDesc,
            outputSampleRate: sampleRate,
            outputChannels: channels,
            outputCodecID: AV_CODEC_ID_PCM_F32LE,
            outputFormatName: "wav",
            totalDuration: 0,
            discardVideo: true,
            onProgress: { _ in }
        )
    }

    // MARK: - 私有：模型路径

    private static func getModelPath() throws -> String {
        guard let path = Bundle.main.path(forResource: "std", ofType: "rnnn") else {
            throw FFmpegLibError.modelNotFound
        }
        return path
    }

    // MARK: - 私有：纯音频处理核心

    /// 打开输入 → 解码音频 → 应用滤镜 → 编码 → 写出
    private static func processAudioFile(
        inputPath: String,
        outputPath: String,
        filterDescription: String,
        outputSampleRate: Int32,
        outputChannels: Int32,
        outputCodecID: AVCodecID,
        outputFormatName: String,
        totalDuration: TimeInterval,
        seekTo: TimeInterval = 0,
        maxDuration: TimeInterval? = nil,
        discardVideo: Bool = false,
        onProgress: @escaping (Double) -> Void
    ) throws {
        // ── 1. 打开输入 ──
        var pFormatCtx: UnsafeMutablePointer<AVFormatContext>?
        var ret = avformat_open_input(&pFormatCtx, inputPath, nil, nil)
        guard ret >= 0, let fmtCtx = pFormatCtx else {
            throw FFmpegLibError.openInputFailed(avErrorString(ret))
        }
        defer { avformat_close_input(&pFormatCtx) }

        ret = avformat_find_stream_info(fmtCtx, nil)
        guard ret >= 0 else { throw FFmpegLibError.streamInfoFailed }

        // ── 2. 找到音频流 ──
        var decoderPtr: UnsafePointer<AVCodec>?
        let audioStreamIdx = av_find_best_stream(fmtCtx, AVMEDIA_TYPE_AUDIO, -1, -1, &decoderPtr, 0)
        guard audioStreamIdx >= 0 else { throw FFmpegLibError.noAudioStream }
        guard let decoder = decoderPtr else { throw FFmpegLibError.decoderNotFound }

        let audioStream = fmtCtx.pointee.streams[Int(audioStreamIdx)]!

        // ── 3. 打开解码器 ──
        var pDecCtx = avcodec_alloc_context3(decoder)
        guard let decCtx = pDecCtx else { throw FFmpegLibError.decoderOpenFailed }
        defer { avcodec_free_context(&pDecCtx) }

        ret = avcodec_parameters_to_context(decCtx, audioStream.pointee.codecpar)
        guard ret >= 0 else { throw FFmpegLibError.decoderOpenFailed }
        ret = avcodec_open2(decCtx, decoder, nil)
        guard ret >= 0 else { throw FFmpegLibError.decoderOpenFailed }

        // ── 4. 构建滤镜图 ──
        var pFilterGraph = avfilter_graph_alloc()
        guard let filterGraph = pFilterGraph else {
            throw FFmpegLibError.filterGraphFailed("avfilter_graph_alloc 失败")
        }
        defer { avfilter_graph_free(&pFilterGraph) }

        var bufferSrcCtx: UnsafeMutablePointer<AVFilterContext>?
        var bufferSinkCtx: UnsafeMutablePointer<AVFilterContext>?

        try setupFilterGraph(
            filterGraph: filterGraph,
            decCtx: decCtx,
            audioStream: audioStream,
            filterDescription: filterDescription,
            bufferSrcCtx: &bufferSrcCtx,
            bufferSinkCtx: &bufferSinkCtx
        )

        guard let srcCtx = bufferSrcCtx, let sinkCtx = bufferSinkCtx else {
            throw FFmpegLibError.filterGraphFailed("滤镜上下文为空")
        }

        // ── 5. 设置输出 ──
        var pOutFmtCtx: UnsafeMutablePointer<AVFormatContext>?
        ret = avformat_alloc_output_context2(&pOutFmtCtx, nil, outputFormatName, outputPath)
        guard ret >= 0, let outFmtCtx = pOutFmtCtx else {
            throw FFmpegLibError.outputFormatFailed
        }
        defer { avformat_free_context(outFmtCtx) }

        guard let outCodec = avcodec_find_encoder(outputCodecID) else {
            throw FFmpegLibError.encoderNotFound
        }

        guard let outStream = avformat_new_stream(outFmtCtx, outCodec) else {
            throw FFmpegLibError.outputStreamFailed
        }

        var pEncCtx = avcodec_alloc_context3(outCodec)
        guard let encCtx = pEncCtx else { throw FFmpegLibError.encoderOpenFailed }
        defer { avcodec_free_context(&pEncCtx) }

        encCtx.pointee.sample_fmt = AV_SAMPLE_FMT_FLT
        encCtx.pointee.sample_rate = outputSampleRate
        av_channel_layout_default(&encCtx.pointee.ch_layout, outputChannels)
        encCtx.pointee.time_base = AVRational(num: 1, den: outputSampleRate)

        if (outFmtCtx.pointee.oformat.pointee.flags & AVFMT_GLOBALHEADER) != 0 {
            encCtx.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER
        }

        ret = avcodec_open2(encCtx, outCodec, nil)
        guard ret >= 0 else { throw FFmpegLibError.encoderOpenFailed }

        ret = avcodec_parameters_from_context(outStream.pointee.codecpar, encCtx)
        guard ret >= 0 else { throw FFmpegLibError.encoderOpenFailed }
        outStream.pointee.time_base = encCtx.pointee.time_base

        // 打开输出文件
        if (outFmtCtx.pointee.oformat.pointee.flags & AVFMT_NOFILE) == 0 {
            ret = avio_open(&outFmtCtx.pointee.pb, outputPath, AVIO_FLAG_WRITE)
            guard ret >= 0 else { throw FFmpegLibError.writeHeaderFailed }
        }

        ret = avformat_write_header(outFmtCtx, nil)
        guard ret >= 0 else { throw FFmpegLibError.writeHeaderFailed }

        // ── 6. seek（如果需要） ──
        if seekTo > 0.5 {
            let seekTs = Int64(seekTo * Double(AV_TIME_BASE))
            av_seek_frame(fmtCtx, -1, seekTs, AVSEEK_FLAG_BACKWARD)
            avcodec_flush_buffers(decCtx)
        }

        // ── 7. 处理循环 ──
        var pPacket = av_packet_alloc()
        guard let packet = pPacket else { throw FFmpegLibError.processingFailed("av_packet_alloc 失败") }
        defer { av_packet_free(&pPacket) }
        var pFrame = av_frame_alloc()
        guard let frame = pFrame else { throw FFmpegLibError.processingFailed("av_frame_alloc 失败") }
        defer { av_frame_free(&pFrame) }
        var pFiltFrame = av_frame_alloc()
        guard let filtFrame = pFiltFrame else { throw FFmpegLibError.processingFailed("av_frame_alloc 失败") }
        defer { av_frame_free(&pFiltFrame) }

        let totalDurationUs = totalDuration * 1_000_000
        let maxDurationTs: Int64? = maxDuration.map { Int64($0 * Double(audioStream.pointee.time_base.den) / Double(audioStream.pointee.time_base.num)) }
        let startPts = audioStream.pointee.start_time != FF_AV_NOPTS_VALUE ? audioStream.pointee.start_time : 0
        var firstPts: Int64 = FF_AV_NOPTS_VALUE

        while av_read_frame(fmtCtx, packet) >= 0 {
            defer { av_packet_unref(packet) }

            guard packet.pointee.stream_index == audioStreamIdx else { continue }

            // 检查是否超出 maxDuration
            if let maxTs = maxDurationTs, packet.pointee.pts != FF_AV_NOPTS_VALUE {
                if firstPts == FF_AV_NOPTS_VALUE { firstPts = packet.pointee.pts }
                if (packet.pointee.pts - firstPts) > maxTs { break }
            }

            ret = avcodec_send_packet(decCtx, packet)
            guard ret >= 0 else { continue }

            while true {
                ret = avcodec_receive_frame(decCtx, frame)
                if ret == averror(EAGAIN) || ret == FF_AVERROR_EOF { break }
                guard ret >= 0 else { break }

                ret = av_buffersrc_add_frame_flags(srcCtx, frame, Int32(AV_BUFFERSRC_FLAG_KEEP_REF))
                guard ret >= 0 else { break }

                while true {
                    ret = av_buffersink_get_frame(sinkCtx, filtFrame)
                    if ret == averror(EAGAIN) || ret == FF_AVERROR_EOF { break }
                    guard ret >= 0 else { break }

                    try encodeAndWrite(
                        encCtx: encCtx,
                        outFmtCtx: outFmtCtx,
                        outStream: outStream,
                        frame: filtFrame
                    )
                    av_frame_unref(filtFrame)
                }

                // 进度更新
                if totalDurationUs > 0, frame.pointee.pts != FF_AV_NOPTS_VALUE {
                    let timeUs = Double(frame.pointee.pts - startPts) *
                        Double(audioStream.pointee.time_base.num) /
                        Double(audioStream.pointee.time_base.den) * 1_000_000
                    let progress = min(1.0, max(0.0, timeUs / totalDurationUs))
                    onProgress(progress)
                }
            }
        }

        // 刷新解码器
        avcodec_send_packet(decCtx, nil)
        while true {
            ret = avcodec_receive_frame(decCtx, frame)
            if ret == averror(EAGAIN) || ret == FF_AVERROR_EOF { break }
            guard ret >= 0 else { break }

            av_buffersrc_add_frame_flags(srcCtx, frame, Int32(AV_BUFFERSRC_FLAG_KEEP_REF))
            while true {
                ret = av_buffersink_get_frame(sinkCtx, filtFrame)
                if ret == averror(EAGAIN) || ret == FF_AVERROR_EOF { break }
                guard ret >= 0 else { break }
                try encodeAndWrite(encCtx: encCtx, outFmtCtx: outFmtCtx, outStream: outStream, frame: filtFrame)
                av_frame_unref(filtFrame)
            }
        }

        // 刷新滤镜
        av_buffersrc_add_frame_flags(srcCtx, nil, 0)
        while true {
            ret = av_buffersink_get_frame(sinkCtx, filtFrame)
            if ret == averror(EAGAIN) || ret == FF_AVERROR_EOF { break }
            guard ret >= 0 else { break }
            try encodeAndWrite(encCtx: encCtx, outFmtCtx: outFmtCtx, outStream: outStream, frame: filtFrame)
            av_frame_unref(filtFrame)
        }

        // 刷新编码器
        avcodec_send_frame(encCtx, nil)
        while true {
            var pOutPacket = av_packet_alloc()
            guard let outPacket = pOutPacket else { break }
            ret = avcodec_receive_packet(encCtx, outPacket)
            if ret == averror(EAGAIN) || ret == FF_AVERROR_EOF {
                av_packet_free(&pOutPacket)
                break
            }
            av_packet_rescale_ts(outPacket, encCtx.pointee.time_base, outStream.pointee.time_base)
            outPacket.pointee.stream_index = outStream.pointee.index
            av_interleaved_write_frame(outFmtCtx, outPacket)
            av_packet_free(&pOutPacket)
        }

        av_write_trailer(outFmtCtx)

        if (outFmtCtx.pointee.oformat.pointee.flags & AVFMT_NOFILE) == 0 {
            avio_closep(&outFmtCtx.pointee.pb)
        }

        onProgress(1.0)
    }

    // MARK: - 私有：视频处理核心（视频 passthrough + 音频降噪）

    private static func processVideoFile(
        inputPath: String,
        outputPath: String,
        filterDescription: String,
        totalDuration: TimeInterval,
        onProgress: @escaping (Double) -> Void
    ) throws {
        // ── 1. 打开输入 ──
        var pFormatCtx: UnsafeMutablePointer<AVFormatContext>?
        var ret = avformat_open_input(&pFormatCtx, inputPath, nil, nil)
        guard ret >= 0, let fmtCtx = pFormatCtx else {
            throw FFmpegLibError.openInputFailed(avErrorString(ret))
        }
        defer { avformat_close_input(&pFormatCtx) }

        ret = avformat_find_stream_info(fmtCtx, nil)
        guard ret >= 0 else { throw FFmpegLibError.streamInfoFailed }

        // ── 2. 找到音频和视频流 ──
        var audioDecoderPtr: UnsafePointer<AVCodec>?
        let audioIdx = av_find_best_stream(fmtCtx, AVMEDIA_TYPE_AUDIO, -1, -1, &audioDecoderPtr, 0)
        guard audioIdx >= 0 else { throw FFmpegLibError.noAudioStream }
        let videoIdx = av_find_best_stream(fmtCtx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard videoIdx >= 0 else { throw FFmpegLibError.noVideoStream }

        let audioStream = fmtCtx.pointee.streams[Int(audioIdx)]!
        let videoStream = fmtCtx.pointee.streams[Int(videoIdx)]!

        // ── 3. 打开音频解码器 ──
        guard let audioDecoder = audioDecoderPtr else { throw FFmpegLibError.decoderNotFound }
        var pDecCtx = avcodec_alloc_context3(audioDecoder)
        guard let decCtx = pDecCtx else { throw FFmpegLibError.decoderOpenFailed }
        defer { avcodec_free_context(&pDecCtx) }

        avcodec_parameters_to_context(decCtx, audioStream.pointee.codecpar)
        avcodec_open2(decCtx, audioDecoder, nil)

        // ── 4. 构建音频滤镜图 ──
        var pFilterGraph = avfilter_graph_alloc()
        guard let filterGraph = pFilterGraph else {
            throw FFmpegLibError.filterGraphFailed("avfilter_graph_alloc 失败")
        }
        defer { avfilter_graph_free(&pFilterGraph) }

        var bufferSrcCtx: UnsafeMutablePointer<AVFilterContext>?
        var bufferSinkCtx: UnsafeMutablePointer<AVFilterContext>?

        try setupFilterGraph(
            filterGraph: filterGraph,
            decCtx: decCtx,
            audioStream: audioStream,
            filterDescription: filterDescription,
            bufferSrcCtx: &bufferSrcCtx,
            bufferSinkCtx: &bufferSinkCtx
        )

        guard let srcCtx = bufferSrcCtx, let sinkCtx = bufferSinkCtx else {
            throw FFmpegLibError.filterGraphFailed("滤镜上下文为空")
        }

        // ── 5. 设置输出 ──
        var pOutFmtCtx: UnsafeMutablePointer<AVFormatContext>?
        ret = avformat_alloc_output_context2(&pOutFmtCtx, nil, nil, outputPath)
        guard ret >= 0, let outFmtCtx = pOutFmtCtx else { throw FFmpegLibError.outputFormatFailed }
        defer { avformat_free_context(outFmtCtx) }

        // 视频流：直接 copy
        guard let outVideoStream = avformat_new_stream(outFmtCtx, nil) else {
            throw FFmpegLibError.outputStreamFailed
        }
        avcodec_parameters_copy(outVideoStream.pointee.codecpar, videoStream.pointee.codecpar)
        outVideoStream.pointee.codecpar.pointee.codec_tag = 0
        outVideoStream.pointee.time_base = videoStream.pointee.time_base

        // 音频流：AAC 编码
        guard let aacCodec = avcodec_find_encoder(AV_CODEC_ID_AAC) else {
            throw FFmpegLibError.encoderNotFound
        }
        guard let outAudioStream = avformat_new_stream(outFmtCtx, aacCodec) else {
            throw FFmpegLibError.outputStreamFailed
        }
        var pEncCtx = avcodec_alloc_context3(aacCodec)
        guard let encCtx = pEncCtx else { throw FFmpegLibError.encoderOpenFailed }
        defer { avcodec_free_context(&pEncCtx) }

        // 从滤镜输出获取格式参数
        let sinkSampleRate = av_buffersink_get_sample_rate(sinkCtx)
        encCtx.pointee.sample_rate = sinkSampleRate
        encCtx.pointee.sample_fmt = AV_SAMPLE_FMT_FLTP
        av_channel_layout_copy(&encCtx.pointee.ch_layout, &decCtx.pointee.ch_layout)
        encCtx.pointee.bit_rate = 192000
        encCtx.pointee.time_base = AVRational(num: 1, den: sinkSampleRate)

        if (outFmtCtx.pointee.oformat.pointee.flags & AVFMT_GLOBALHEADER) != 0 {
            encCtx.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER
        }

        ret = avcodec_open2(encCtx, aacCodec, nil)
        guard ret >= 0 else { throw FFmpegLibError.encoderOpenFailed }

        avcodec_parameters_from_context(outAudioStream.pointee.codecpar, encCtx)
        outAudioStream.pointee.time_base = encCtx.pointee.time_base

        // 打开输出文件
        if (outFmtCtx.pointee.oformat.pointee.flags & AVFMT_NOFILE) == 0 {
            ret = avio_open(&outFmtCtx.pointee.pb, outputPath, AVIO_FLAG_WRITE)
            guard ret >= 0 else { throw FFmpegLibError.writeHeaderFailed }
        }

        ret = avformat_write_header(outFmtCtx, nil)
        guard ret >= 0 else { throw FFmpegLibError.writeHeaderFailed }

        // 音频重采样（滤镜输出 FLT → AAC 需要 FLTP）
        var pSwrCtx: OpaquePointer? = nil
        var sinkChLayout = AVChannelLayout()
        av_buffersink_get_ch_layout(sinkCtx, &sinkChLayout)
        let sinkFmt = AVSampleFormat(rawValue: av_buffersink_get_format(sinkCtx))
        ret = swr_alloc_set_opts2(
            &pSwrCtx,
            &encCtx.pointee.ch_layout, AV_SAMPLE_FMT_FLTP, sinkSampleRate,
            &sinkChLayout, sinkFmt, sinkSampleRate,
            0, nil
        )
        if ret >= 0, let swrCtx = pSwrCtx {
            swr_init(swrCtx)
            defer { swr_free(&pSwrCtx) }
        }

        // ── 6. 处理循环 ──
        var pPacket = av_packet_alloc()
        guard let packet = pPacket else { throw FFmpegLibError.processingFailed("av_packet_alloc 失败") }
        defer { av_packet_free(&pPacket) }
        var pFrame = av_frame_alloc()
        guard let frame = pFrame else { throw FFmpegLibError.processingFailed("av_frame_alloc 失败") }
        defer { av_frame_free(&pFrame) }
        var pFiltFrame = av_frame_alloc()
        guard let filtFrame = pFiltFrame else { throw FFmpegLibError.processingFailed("av_frame_alloc 失败") }
        defer { av_frame_free(&pFiltFrame) }

        let totalDurationUs = totalDuration * 1_000_000

        while av_read_frame(fmtCtx, packet) >= 0 {
            defer { av_packet_unref(packet) }

            if packet.pointee.stream_index == videoIdx {
                // 视频包：直接 copy（调整 time_base）
                av_packet_rescale_ts(packet, videoStream.pointee.time_base, outVideoStream.pointee.time_base)
                packet.pointee.stream_index = outVideoStream.pointee.index
                av_interleaved_write_frame(outFmtCtx, packet)
            } else if packet.pointee.stream_index == audioIdx {
                // 音频包：解码 → 滤镜 → 编码
                avcodec_send_packet(decCtx, packet)

                while true {
                    ret = avcodec_receive_frame(decCtx, frame)
                    if ret == averror(EAGAIN) || ret == FF_AVERROR_EOF { break }
                    guard ret >= 0 else { break }

                    av_buffersrc_add_frame_flags(srcCtx, frame, Int32(AV_BUFFERSRC_FLAG_KEEP_REF))

                    while true {
                        ret = av_buffersink_get_frame(sinkCtx, filtFrame)
                        if ret == averror(EAGAIN) || ret == FF_AVERROR_EOF { break }
                        guard ret >= 0 else { break }

                        try encodeAndWrite(
                            encCtx: encCtx,
                            outFmtCtx: outFmtCtx,
                            outStream: outAudioStream,
                            frame: filtFrame
                        )
                        av_frame_unref(filtFrame)
                    }

                    // 进度
                    if totalDurationUs > 0, frame.pointee.pts != FF_AV_NOPTS_VALUE {
                        let tb = audioStream.pointee.time_base
                        let timeUs = Double(frame.pointee.pts) * Double(tb.num) / Double(tb.den) * 1_000_000
                        onProgress(min(1.0, max(0.0, timeUs / totalDurationUs)))
                    }
                }
            }
        }

        // 刷新解码器 + 滤镜 + 编码器
        flushPipeline(decCtx: decCtx, srcCtx: srcCtx, sinkCtx: sinkCtx, encCtx: encCtx, outFmtCtx: outFmtCtx, outStream: outAudioStream, frame: frame, filtFrame: filtFrame)

        av_write_trailer(outFmtCtx)
        if (outFmtCtx.pointee.oformat.pointee.flags & AVFMT_NOFILE) == 0 {
            avio_closep(&outFmtCtx.pointee.pb)
        }
        onProgress(1.0)
    }

    // MARK: - 私有：构建滤镜图

    private static func setupFilterGraph(
        filterGraph: UnsafeMutablePointer<AVFilterGraph>,
        decCtx: UnsafeMutablePointer<AVCodecContext>,
        audioStream: UnsafeMutablePointer<AVStream>,
        filterDescription: String,
        bufferSrcCtx: inout UnsafeMutablePointer<AVFilterContext>?,
        bufferSinkCtx: inout UnsafeMutablePointer<AVFilterContext>?
    ) throws {
        guard let bufferSrc = avfilter_get_by_name("abuffer"),
              let bufferSink = avfilter_get_by_name("abuffersink") else {
            throw FFmpegLibError.filterGraphFailed("找不到 abuffer/abuffersink 滤镜")
        }

        // 描述输入格式
        let tb = audioStream.pointee.time_base
        let sampleRate = decCtx.pointee.sample_rate
        let sampleFmt = av_get_sample_fmt_name(decCtx.pointee.sample_fmt)
        let sampleFmtStr = sampleFmt.map { String(cString: $0) } ?? "fltp"

        var chLayoutBuf = [CChar](repeating: 0, count: 64)
        av_channel_layout_describe(&decCtx.pointee.ch_layout, &chLayoutBuf, 64)
        let chLayoutStr = String(cString: chLayoutBuf)

        let args = "time_base=\(tb.num)/\(tb.den):sample_rate=\(sampleRate):sample_fmt=\(sampleFmtStr):channel_layout=\(chLayoutStr)"

        var ret = avfilter_graph_create_filter(
            &bufferSrcCtx, bufferSrc, "in", args, nil, filterGraph
        )
        guard ret >= 0 else {
            throw FFmpegLibError.filterGraphFailed("abuffer 创建失败: \(avErrorString(ret))")
        }

        ret = avfilter_graph_create_filter(
            &bufferSinkCtx, bufferSink, "out", nil, nil, filterGraph
        )
        guard ret >= 0 else {
            throw FFmpegLibError.filterGraphFailed("abuffersink 创建失败: \(avErrorString(ret))")
        }

        // 使用 avfilter_graph_parse_ptr 解析滤镜描述
        var inputs: UnsafeMutablePointer<AVFilterInOut>? = avfilter_inout_alloc()
        var outputs: UnsafeMutablePointer<AVFilterInOut>? = avfilter_inout_alloc()
        defer {
            avfilter_inout_free(&inputs)
            avfilter_inout_free(&outputs)
        }

        outputs!.pointee.name = av_strdup("in")
        outputs!.pointee.filter_ctx = bufferSrcCtx
        outputs!.pointee.pad_idx = 0
        outputs!.pointee.next = nil

        inputs!.pointee.name = av_strdup("out")
        inputs!.pointee.filter_ctx = bufferSinkCtx
        inputs!.pointee.pad_idx = 0
        inputs!.pointee.next = nil

        ret = avfilter_graph_parse_ptr(filterGraph, filterDescription, &inputs, &outputs, nil)
        guard ret >= 0 else {
            throw FFmpegLibError.filterGraphFailed("滤镜解析失败: \(avErrorString(ret)), 描述: \(filterDescription)")
        }

        ret = avfilter_graph_config(filterGraph, nil)
        guard ret >= 0 else {
            throw FFmpegLibError.filterGraphFailed("滤镜图配置失败: \(avErrorString(ret))")
        }
    }

    // MARK: - 私有：编码并写出

    private static func encodeAndWrite(
        encCtx: UnsafeMutablePointer<AVCodecContext>,
        outFmtCtx: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>,
        frame: UnsafeMutablePointer<AVFrame>
    ) throws {
        var ret = avcodec_send_frame(encCtx, frame)
        guard ret >= 0 else { return }

        while true {
            var pOutPacket = av_packet_alloc()
            guard let outPacket = pOutPacket else { break }
            ret = avcodec_receive_packet(encCtx, outPacket)
            if ret == averror(EAGAIN) || ret == FF_AVERROR_EOF {
                av_packet_free(&pOutPacket)
                break
            }
            guard ret >= 0 else {
                av_packet_free(&pOutPacket)
                break
            }

            av_packet_rescale_ts(outPacket, encCtx.pointee.time_base, outStream.pointee.time_base)
            outPacket.pointee.stream_index = outStream.pointee.index
            av_interleaved_write_frame(outFmtCtx, outPacket)
            av_packet_free(&pOutPacket)
        }
    }

    // MARK: - 私有：刷新管线

    private static func flushPipeline(
        decCtx: UnsafeMutablePointer<AVCodecContext>,
        srcCtx: UnsafeMutablePointer<AVFilterContext>,
        sinkCtx: UnsafeMutablePointer<AVFilterContext>,
        encCtx: UnsafeMutablePointer<AVCodecContext>,
        outFmtCtx: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>,
        frame: UnsafeMutablePointer<AVFrame>,
        filtFrame: UnsafeMutablePointer<AVFrame>
    ) {
        // 刷新解码器
        avcodec_send_packet(decCtx, nil)
        while avcodec_receive_frame(decCtx, frame) >= 0 {
            av_buffersrc_add_frame_flags(srcCtx, frame, Int32(AV_BUFFERSRC_FLAG_KEEP_REF))
            while av_buffersink_get_frame(sinkCtx, filtFrame) >= 0 {
                try? encodeAndWrite(encCtx: encCtx, outFmtCtx: outFmtCtx, outStream: outStream, frame: filtFrame)
                av_frame_unref(filtFrame)
            }
        }

        // 刷新滤镜
        av_buffersrc_add_frame_flags(srcCtx, nil, 0)
        while av_buffersink_get_frame(sinkCtx, filtFrame) >= 0 {
            try? encodeAndWrite(encCtx: encCtx, outFmtCtx: outFmtCtx, outStream: outStream, frame: filtFrame)
            av_frame_unref(filtFrame)
        }

        // 刷新编码器
        avcodec_send_frame(encCtx, nil)
        while true {
            var pPkt = av_packet_alloc()
            guard let pkt = pPkt else { break }
            let ret = avcodec_receive_packet(encCtx, pkt)
            if ret < 0 {
                av_packet_free(&pPkt)
                break
            }
            av_packet_rescale_ts(pkt, encCtx.pointee.time_base, outStream.pointee.time_base)
            pkt.pointee.stream_index = outStream.pointee.index
            av_interleaved_write_frame(outFmtCtx, pkt)
            av_packet_free(&pPkt)
        }
    }

    // MARK: - 工具函数

    /// 将 FFmpeg 错误码转换为可读字符串
    private static func avErrorString(_ errnum: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        av_strerror(errnum, &buf, 128)
        return String(cString: buf)
    }

    /// 将 Swift 的 EAGAIN 转换为 FFmpeg 的 AVERROR(EAGAIN)
    private static func averror(_ e: Int32) -> Int32 {
        return -e
    }
}

#endif
