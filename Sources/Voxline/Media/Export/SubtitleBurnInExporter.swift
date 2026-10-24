#if os(macOS) || os(iOS)
@preconcurrency import AVFoundation
import CoreImage
import CoreText
import Foundation
import VoxlineCore

public enum BurnInCodec: String, CaseIterable, Sendable {
    case h264, hevc
    public var label: String { self == .h264 ? "H.264" : "HEVC" }
}

public enum BurnInQuality: String, CaseIterable, Sendable {
    case original, fullHD
    public var label: String { self == .original ? String(localized: "源尺寸 · 最高质量", bundle: voxlineLocalizationBundle) : String(localized: "最高 1080p · 最高质量", bundle: voxlineLocalizationBundle) }
    func preset(codec: BurnInCodec) -> String {
        switch (codec, self) {
        case (.h264, .original): AVAssetExportPresetHighestQuality
        case (.hevc, .original): AVAssetExportPresetHEVCHighestQuality
        case (.h264, .fullHD): AVAssetExportPreset1920x1080
        case (.hevc, .fullHD): AVAssetExportPresetHEVC1920x1080
        }
    }
}

public struct BurnInOptions: Sendable, Equatable {
    public var kind: SRTOutputKind = .bilingual
    public var codec: BurnInCodec = .h264
    public var quality: BurnInQuality = .original
    /// Font size at a 1080-pixel canvas height; other dimensions scale proportionally.
    public var fontSize: Double = 36
    public init() {}
}

public enum BurnInError: LocalizedError, Equatable {
    case videoRequired, missingMedia, unsupportedColor, unsupportedEncoding, invalidGeometry
    case invalidOutput, failure(String)
    public var errorDescription: String? {
        switch self {
        case .videoRequired: String(localized: "字幕烧录需要包含画面的视频。", bundle: voxlineLocalizationBundle)
        case .missingMedia: String(localized: "本地媒体未关联，请先重新关联并确认音轨。", bundle: voxlineLocalizationBundle)
        case .unsupportedColor: String(localized: "当前烧录仅支持 SDR 视频；HDR 或广色域输入不会自动转换。", bundle: voxlineLocalizationBundle)
        case .unsupportedEncoding: String(localized: "系统不支持所选编码与质量，请选择其他输出设置。", bundle: voxlineLocalizationBundle)
        case .invalidGeometry: String(localized: "无法确定视频的尺寸、方向或帧时间。", bundle: voxlineLocalizationBundle)
        case .invalidOutput: String(localized: "导出文件的编码、尺寸、时长或音轨不符合所选输出。", bundle: voxlineLocalizationBundle)
        case .failure(let reason): String(localized: "烧录失败：\(reason)", bundle: voxlineLocalizationBundle)
        }
    }
}

/// One immutable subtitle snapshot and one Core Image composition serve both preview and export.
@MainActor
public final class SubtitleBurnInPlan {
    public let asset: AVComposition
    public let videoComposition: AVVideoComposition
    public let sourceURL: URL
    public let renderSize: CGSize
    public let duration: CMTime
    private let hasScopedAccess: Bool
    private var accessReleased = false

    fileprivate init(asset: AVComposition, videoComposition: AVVideoComposition, sourceURL: URL,
         duration: CMTime, hasScopedAccess: Bool) {
        self.asset = asset
        self.videoComposition = videoComposition
        self.sourceURL = sourceURL
        self.renderSize = videoComposition.renderSize
        self.duration = duration
        self.hasScopedAccess = hasScopedAccess
    }

    public func releaseAccess() {
        if hasScopedAccess && !accessReleased { sourceURL.stopAccessingSecurityScopedResource() }
        accessReleased = true
    }

    public func preview(atMilliseconds time: Int64, maximumSize: CGSize = .zero) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = videoComposition
        generator.maximumSize = maximumSize
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try await withTaskCancellationHandler {
            try await generator.image(at: CMTime(value: time, timescale: 1000))
        } onCancel: { generator.cancelAllCGImageGeneration() }
        try Task.checkCancellation()
        return frame.image
    }
}

public enum SubtitleBurnInExporter {
    @MainActor
    public static func composition(for item: TaskMediaItem, options: BurnInOptions,
                                   mediaStore: LocalMediaStore = .shared,
                                   inspector: MediaInspector = .shared) async throws -> SubtitleBurnInPlan {
        guard item.kind == .video else { throw BurnInError.videoRequired }
        guard let identity = item.media,
              let bookmark = try await mediaStore.resolve(mediaID: item.id, identity: identity) else {
            throw BurnInError.missingMedia
        }
        let access = bookmark.url.startAccessingSecurityScopedResource()
        var retained = false
        defer { if access && !retained { bookmark.url.stopAccessingSecurityScopedResource() } }
        let inspection = try await inspector.inspect(bookmark.url)
        try inspection.requireDecodableVideo()
        guard identity.matchesContent(of: try inspection.identity(audioTrackID: identity.audioTrackID)) else {
            throw DomainValidationError.differentMedia
        }
        // Share timeline and text projection with SRT, without constructing another full export.
        guard !item.cues.isEmpty else { throw SubtitleExportError.emptyCues }
        let cues = try SubtitleCue.clampedToMedia(item.cues, media: identity)
        for cue in cues { _ = try SubtitleExporter.subtitleText(for: cue, kind: options.kind) }
        guard options.fontSize.isFinite, options.fontSize > 0 else { throw BurnInError.invalidGeometry }
        let source = AVURLAsset(url: bookmark.url)
        guard let video = try await source.loadTracks(withMediaType: .video).first,
              let audio = try await source.loadTracks(withMediaType: .audio).first(where: { $0.trackID == identity.audioTrackID }) else {
            throw BurnInError.videoRequired
        }
        let formats = try await video.load(.formatDescriptions)
        guard !(try await video.load(.mediaCharacteristics)).contains(.containsHDRVideo) else { throw BurnInError.unsupportedColor }
        for format in formats {
            guard let values = CMFormatDescriptionGetExtensions(format) else { continue }
            let extensions = values as NSDictionary
            let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction] as? String
            let primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries] as? String
            if transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
                || transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
                || primaries == kCVImageBufferColorPrimaries_ITU_R_2020 as String
                || primaries == kCVImageBufferColorPrimaries_P3_D65 as String {
                throw BurnInError.unsupportedColor
            }
        }
        let composition = AVMutableComposition()
        for track in [video, audio] {
            guard let output = composition.addMutableTrack(withMediaType: track.mediaType,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw BurnInError.unsupportedEncoding
            }
            let range = try await track.load(.timeRange)
            try output.insertTimeRange(range, of: track, at: range.start)
            if track.mediaType == .video { output.preferredTransform = try await track.load(.preferredTransform) }
        }
        let renderer = BurnInTextRenderer(cues: cues, options: options)
        let videoComposition = try await AVMutableVideoComposition.videoComposition(with: composition) { request in
            do {
                // AVFoundation supplies a clamped CI image with an infinite extent.
                let sourceFrame = request.sourceImage.cropped(to: CGRect(origin: .zero, size: request.renderSize))
                let frame = try renderer.frame(source: sourceFrame, time: request.compositionTime.seconds)
                request.finish(with: frame, context: renderer.context)
            } catch { request.finish(with: error) }
        }
        let size = videoComposition.renderSize
        let frameDuration = videoComposition.frameDuration
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              frameDuration.isValid, frameDuration.seconds.isFinite, frameDuration.seconds > 0 else {
            throw BurnInError.invalidGeometry
        }
        let duration = try await composition.load(.duration)
        try Task.checkCancellation()
        retained = true
        return SubtitleBurnInPlan(asset: composition, videoComposition: videoComposition,
                                  sourceURL: bookmark.url, duration: duration, hasScopedAccess: access)
    }

    @MainActor
    public static func export(_ plan: SubtitleBurnInPlan, to destination: URL, codec: BurnInCodec, quality: BurnInQuality,
                              allowOverwrite: Bool = false,
                              progress: @escaping @MainActor (Double) -> Void) async throws {
        let outputFile = try VideoExportDestination(destination: destination, source: plan.sourceURL, allowOverwrite: allowOverwrite)
        try Task.checkCancellation()
        let preset = quality.preset(codec: codec)
        guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: plan.asset, outputFileType: .mp4),
              let session = AVAssetExportSession(asset: plan.asset, presetName: preset) else {
            throw BurnInError.unsupportedEncoding
        }
        session.videoComposition = plan.videoComposition
        // Process the selected audio instead of passing through AAC packets with trimmed boundaries.
        guard let selectedAudio = try await plan.asset.loadTracks(withMediaType: .audio).first else {
            throw BurnInError.invalidOutput
        }
        let expectedAudioRange = try await selectedAudio.load(.timeRange)
        let audioParameters = AVMutableAudioMixInputParameters(track: selectedAudio)
        audioParameters.setVolume(1, at: .zero)
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [audioParameters]
        session.audioMix = audioMix
        let temporary = outputFile.temporaryURL
        let monitor = Task { @MainActor in
            for await state in session.states(updateInterval: 0.2) {
                if case .exporting(let value) = state { progress(value.fractionCompleted) }
            }
        }
        let cancelExport: @MainActor @Sendable () -> Void = { session.cancelExport() }
        defer { monitor.cancel() }
        do {
            try Task.checkCancellation()
            try await withTaskCancellationHandler {
                try await session.export(to: temporary, as: .mp4)
            } onCancel: { Task { @MainActor in cancelExport() } }
            try Task.checkCancellation()
            let exported = AVURLAsset(url: temporary)
            let audioTracks = try await exported.loadTracks(withMediaType: .audio)
            guard let video = try await exported.loadTracks(withMediaType: .video).first,
                  let audio = audioTracks.first, audioTracks.count == 1 else { throw BurnInError.invalidOutput }
            let formats = try await video.load(.formatDescriptions)
            let expectedCodec = codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
            let actualSize = try await video.load(.naturalSize)
            let actualDuration = try await exported.load(.duration)
            let actualAudioRange = try await audio.load(.timeRange)
            guard formats.allSatisfy({ CMFormatDescriptionGetMediaSubType($0) == expectedCodec }),
                  !formats.isEmpty, actualDuration.seconds.isFinite, actualDuration.seconds > 0,
                  abs(actualDuration.seconds - plan.duration.seconds) < 0.5,
                  abs(actualAudioRange.duration.seconds - expectedAudioRange.duration.seconds) < 0.5,
                  try await audio.load(.isDecodable), try await video.load(.isDecodable),
                  actualSize.width > 0, actualSize.height > 0 else { throw BurnInError.invalidOutput }
            if quality == .original {
                guard abs(actualSize.width - plan.renderSize.width) < 2,
                      abs(actualSize.height - plan.renderSize.height) < 2 else { throw BurnInError.invalidOutput }
            }
            try Task.checkCancellation()
            try outputFile.publish()
            progress(1)
        } catch {
            session.cancelExport()
            do { try outputFile.removeTemporaryFile() }
            catch let cleanupError { throw BurnInError.failure(String(localized: "\(error.localizedDescription)；临时文件清理失败：\(cleanupError.localizedDescription)", bundle: voxlineLocalizationBundle)) }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}

/// Core Text lays out the active interval on the render thread; one overlay is retained.
fileprivate final class BurnInTextRenderer: @unchecked Sendable {
    // One rendering context per composition; retain subtitle overlays, not intermediate video frames.
    let context = CIContext(options: [.cacheIntermediates: false, .name: "Voxline Subtitle Burn-In"])
    private let cues: [SubtitleCue]
    private let timeline: SubtitleTimeline
    private let options: BurnInOptions
    private let lock = NSLock()
    private var cachedIndices: [Int] = []
    private var cachedSize: CGSize = .zero
    private var cachedOverlay: CIImage?

    init(cues: [SubtitleCue], options: BurnInOptions) {
        self.cues = cues; self.options = options; timeline = SubtitleTimeline(cues: cues)
    }

    func frame(source: CIImage, time: Double) throws -> CIImage {
        guard let interval = timeline.interval(atMilliseconds: Int64((time * 1000).rounded(.down))) else { return source }
        let overlay: CIImage = try lock.withLock {
            let size = source.extent.size
            if cachedIndices != interval.cueIndices || cachedSize != size {
                let text = try interval.cueIndices.map { try SubtitleExporter.subtitleText(for: cues[$0], kind: options.kind) }.joined(separator: "\n")
                let (frame, width, height, padding) = try layout(text: text, size: size)
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    throw BurnInError.failure(String(localized: "无法分配字幕绘制缓冲。", bundle: voxlineLocalizationBundle))
                }
                context.setFillColor(CGColor(gray: 0, alpha: 0.72))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.translateBy(x: padding, y: padding)
                CTFrameDraw(frame, context)
                guard let image = context.makeImage() else { throw BurnInError.failure(String(localized: "无法生成字幕图像。", bundle: voxlineLocalizationBundle)) }
                cachedOverlay = CIImage(cgImage: image).transformed(by: CGAffineTransform(
                    translationX: source.extent.midX - Double(width) / 2,
                    y: source.extent.minY + size.height * 0.05))
                cachedIndices = interval.cueIndices
                cachedSize = size
            }
            guard let overlay = cachedOverlay else { throw BurnInError.failure(String(localized: "字幕图像未生成。", bundle: voxlineLocalizationBundle)) }
            return overlay
        }
        return overlay.composited(over: source).cropped(to: source.extent)
    }

    private func layout(text: String, size: CGSize) throws -> (CTFrame, Int, Int, Double) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width < Double(Int.max), size.height < Double(Int.max) else { throw BurnInError.invalidGeometry }
        var fontSize = options.fontSize * size.height / 1080
        let width = Int((size.width * 0.9).rounded(.down))
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafePointer(to: &alignment) {
            CTParagraphStyleCreate([CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: $0)], 1)
        }
        // Long dialogue uses the same complete, fitted layout in preview and export.
        while fontSize > 0 {
            let padding = min(max(2, fontSize * 0.35), size.height * 0.05)
            let availableWidth = Double(width) - 2 * padding
            guard availableWidth > 0 else { throw BurnInError.invalidGeometry }
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("PingFangSC-Regular" as CFString, fontSize, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph
            ])
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let measured = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: attributed.length), nil,
                CGSize(width: availableWidth, height: .greatestFiniteMagnitude), nil)
            guard measured.height.isFinite else { throw BurnInError.invalidGeometry }
            let height = Int(ceil(measured.height + padding * 2 + 1))
            if height > 0, Double(height) <= size.height * 0.8 {
                let path = CGPath(rect: CGRect(x: 0, y: 0, width: availableWidth, height: Double(height) - 2 * padding), transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil)
                if CTFrameGetVisibleStringRange(frame).length == attributed.length {
                    return (frame, width, height, padding)
                }
            }
            fontSize *= 0.85
            if fontSize < 0.1 { throw BurnInError.invalidGeometry }
        }
        throw BurnInError.invalidGeometry
    }
}

#endif
