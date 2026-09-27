import AVFoundation
import AppKit
import CoreText
import Foundation

/// Mock 片源的媒体文件生成器：AVAssetWriter 合成带画面/声音的样例 MP4。
///
/// 画面：每集固定色底 + 大号"分:秒"计时文字（肉眼可确认播放/seek 生效）+ 集数角标；
/// 声音：五声音阶旋律正弦波（可确认音频输出）。
/// 生成结果缓存到磁盘，同集第二次播放直接复用。
///
/// ⚠️ 喂数据必须走 `requestMediaDataWhenReady(on:using:)`：实测在 Swift 并发线程上
/// 手动轮询 `isReadyForMoreMediaData` 会永远拿到 false（起播闸门不翻转），
/// 官方回调模式在专用串行队列上推进，无此问题。
enum MockStreamGenerator {
    static let sampleRate: Double = 22050

    struct Config {
        let fps: Int32
        let width: Int
        let height: Int
        let videoBitRate: Int
        let audioBitRate: Int

        static let standard = Config(
            fps: 15, width: 320, height: 180,
            videoBitRate: 250_000, audioBitRate: 48_000
        )
    }

    /// 生成一集样例视频（异步；阻塞的编码工作在 dispatch 线程上执行）
    static func writeEpisode(
        episodeNumber: Int,
        duration: TimeInterval,
        outputURL: URL,
        config: Config = .standard
    ) async throws {
        if FileManager.default.fileExists(atPath: outputURL.path) { return }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // 先写临时文件再替换：中途失败/被杀不会留下"半成品"被当成完整文件复用
        let tmpURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)-\(outputURL.lastPathComponent)")

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        try write(to: tmpURL, episodeNumber: episodeNumber, duration: duration, config: config)
                        cont.resume(returning: ())
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try? FileManager.default.removeItem(at: tmpURL)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: outputURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw error
        }
    }

    /// 阻塞版生成（dispatch 线程上调用）
    private static func write(to url: URL, episodeNumber: Int, duration: TimeInterval, config: Config) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: config.videoBitRate
            ]
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: config.width,
            kCVPixelBufferHeightKey as String: config.height
        ])
        writer.add(videoInput)

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: config.audioBitRate
        ])
        audioInput.expectsMediaDataInRealTime = false
        writer.add(audioInput)

        guard writer.startWriting() else {
            throw genError("无法开始写入样例视频")
        }
        writer.startSession(atSourceTime: .zero)

        // 两条轨道各自在专用串行队列上喂数据；任一失败立即收尾并记录错误
        let failure = FailureBox()
        let group = DispatchGroup()
        group.enter() // video
        group.enter() // audio

        // ---- 视频轨道 ----
        let totalFrames = max(Int(duration * Double(config.fps)), Int(config.fps))
        // 每集固定色相，集与集之间肉眼可区分
        let hue = (Double(episodeNumber) * 0.23).truncatingRemainder(dividingBy: 1.0)
        var videoFrame = 0
        let videoQueue = DispatchQueue(label: "nagomiani.mock.video")
        videoInput.requestMediaDataWhenReady(on: videoQueue) {
            while videoInput.isReadyForMoreMediaData {
                if let error = failure.get() {
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                if videoFrame >= totalFrames {
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                do {
                    try appendVideoFrame(to: adaptor, writer: writer, config: config,
                                         hue: hue, episodeNumber: episodeNumber, frame: videoFrame)
                    videoFrame += 1
                } catch {
                    failure.set(error)
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
            }
        }

        // ---- 音频轨道 ----
        let totalAudioFrames = Int(duration * sampleRate)
        var audioOffset = 0
        let audioQueue = DispatchQueue(label: "nagomiani.mock.audio")
        audioInput.requestMediaDataWhenReady(on: audioQueue) {
            while audioInput.isReadyForMoreMediaData {
                if let error = failure.get() {
                    audioInput.markAsFinished()
                    group.leave()
                    return
                }
                if audioOffset >= totalAudioFrames {
                    audioInput.markAsFinished()
                    group.leave()
                    return
                }
                do {
                    let frames = try appendAudioChunk(to: audioInput, writer: writer,
                                                      offset: audioOffset, totalFrames: totalAudioFrames)
                    audioOffset += frames
                } catch {
                    failure.set(error)
                    audioInput.markAsFinished()
                    group.leave()
                    return
                }
            }
        }

        // 等待两轨喂数结束（阻塞发生在 dispatch 线程，无碍）
        group.wait()
        if let error = failure.get() { throw error }

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed {
            throw writer.error ?? genError("样例视频写入未完成")
        }
    }

    /// 跨队列传递首个错误（只记第一个）
    private final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var error: Error?

        func set(_ value: Error) {
            lock.lock()
            if error == nil { error = value }
            lock.unlock()
        }

        func get() -> Error? {
            lock.lock()
            defer { lock.unlock() }
            return error
        }
    }

    // MARK: - 视频帧

    private static func appendVideoFrame(
        to adaptor: AVAssetWriterInputPixelBufferAdaptor,
        writer: AVAssetWriter,
        config: Config,
        hue: Double,
        episodeNumber: Int,
        frame: Int
    ) throws {
        guard let pixelBuffer = makePixelBuffer(adaptor: adaptor, config: config) else {
            throw genError("无法创建像素缓冲")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = makeContext(pixelBuffer: pixelBuffer) else {
            throw genError("无法创建绘制上下文")
        }
        drawFrame(context: context, config: config, hue: hue,
                  episodeNumber: episodeNumber, elapsed: Double(frame) / Double(config.fps))

        let pts = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(config.fps))
        if !adaptor.append(pixelBuffer, withPresentationTime: pts) {
            throw writer.error ?? genError("视频帧写入失败")
        }
    }

    private static func makePixelBuffer(adaptor: AVAssetWriterInputPixelBufferAdaptor, config: Config) -> CVPixelBuffer? {
        if let pool = adaptor.pixelBufferPool {
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            if let buffer { return buffer }
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, config.width, config.height, kCVPixelFormatType_32BGRA, nil, &buffer)
        return buffer
    }

    private static func makeContext(pixelBuffer: CVPixelBuffer) -> CGContext? {
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        // 32BGRA 在 CG 侧 = 小端序 + premultipliedFirst
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        return CGContext(
            data: base,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        )
    }

    private static func drawFrame(context: CGContext, config: Config, hue: Double, episodeNumber: Int, elapsed: Double) {
        let width = CGFloat(config.width)
        let height = CGFloat(config.height)
        context.setFillColor(NSColor(hue: hue, saturation: 0.55, brightness: 0.42, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let total = Int(elapsed.rounded())
        let clock = String(format: "%d:%02d", total / 60, total % 60)
        drawText(clock, font: CTFontCreateWithName("Menlo-Bold" as CFString, 40, nil),
                 color: NSColor.white.cgColor, in: context, centeredAt: height * 0.58)
        drawText("NagomiAni Mock · 第 \(episodeNumber) 集",
                 font: CTFontCreateWithName("PingFang SC" as CFString, 14, nil),
                 color: NSColor.white.withAlphaComponent(0.85).cgColor,
                 in: context, centeredAt: height * 0.24)
    }

    /// CoreText 直接往 CG 上下文画一行水平居中的文字（CG 原点在左下）
    private static func drawText(_ text: String, font: CTFont, color: CGColor, in context: CGContext, centeredAt y: CGFloat) {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color
        ]
        guard let attrString = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else { return }
        let line = CTLineCreateWithAttributedString(attrString)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.textPosition = CGPoint(x: (CGFloat(context.width) - width) / 2, y: y)
        CTLineDraw(line, context)
    }

    // MARK: - 音频

    /// 追加一秒 PCM（不足一秒时取剩余），返回本批帧数
    private static func appendAudioChunk(
        to input: AVAssetWriterInput,
        writer: AVAssetWriter,
        offset: Int,
        totalFrames: Int
    ) throws -> Int {
        var format: CMFormatDescription?
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &format) == noErr, let format else {
            throw genError("无法创建音频格式描述")
        }

        let frames = min(Int(sampleRate), totalFrames - offset)
        let samples = Self.pcmChunk(offset: offset, frames: frames)
        let pts = CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(sampleRate))
        let timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var blockBuffer: CMBlockBuffer?
        let byteCount = samples.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount,
                                                 blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: byteCount, flags: 0,
                                                 blockBufferOut: &blockBuffer) == noErr,
              let blockBuffer else {
            throw genError("无法创建音频块缓冲")
        }
        let replaced = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard replaced == noErr else { throw genError("音频数据填充失败") }

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: blockBuffer, formatDescription: format,
                                        sampleCount: CMItemCount(frames), sampleTimingEntryCount: 1,
                                        sampleTimingArray: [timing], sampleSizeEntryCount: 0,
                                        sampleSizeArray: nil, sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer else {
            throw genError("无法创建音频样本缓冲")
        }
        if !input.append(sampleBuffer) {
            throw writer.error ?? genError("音频样本写入失败")
        }
        return frames
    }

    /// 生成一段 PCM：五声音阶旋律（每 0.5s 换音），轻音量正弦
    private static func pcmChunk(offset: Int, frames: Int) -> Data {
        let scale: [Double] = [220.0, 261.63, 293.66, 329.63, 392.0]
        var data = Data(count: frames * 2)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let ptr = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                let t = Double(offset + i) / sampleRate
                let note = scale[(Int(t * 2)) % scale.count]
                // 0.2s 渐入渐出防爆破音
                let phase = (t * 2).truncatingRemainder(dividingBy: 1.0)
                let envelope = min(phase / 0.1, 1.0) * min((1.0 - phase) / 0.1, 1.0)
                let value = sin(2.0 * .pi * note * t) * 0.18 * max(envelope, 0)
                ptr[i] = Int16(clamping: Int(value * Double(Int16.max)))
            }
        }
        return data
    }

    private static func genError(_ message: String) -> NSError {
        NSError(domain: "MockStreamGenerator", code: -3,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
