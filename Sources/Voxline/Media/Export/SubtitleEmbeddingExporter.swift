@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import VoxlineCore

public enum SubtitleEmbeddingError: LocalizedError {
    case unsupportedFormat, invalidText, invalidOutput, videoRequired, missingMedia
    case failure(String)
    public var errorDescription: String? {
        switch self {
        case .videoRequired: String(localized: "内封字幕需要视频。", bundle: voxlineLocalizationBundle)
        case .missingMedia: String(localized: "本地媒体尚未关联。", bundle: voxlineLocalizationBundle)
        case .failure(let reason): String(localized: "内封字幕失败：\(reason)", bundle: voxlineLocalizationBundle)
        case .unsupportedFormat: String(localized: "系统不支持将当前音视频封装为 MP4 软字幕。", bundle: voxlineLocalizationBundle)
        case .invalidText: String(localized: "字幕文本无法编码为内封字幕。", bundle: voxlineLocalizationBundle)
        case .invalidOutput: String(localized: "内封字幕成品的轨道或时间不符合源文件。", bundle: voxlineLocalizationBundle)
        }
    }
}

/// Remux encoded media and one selectable tx3g track without drawing into video frames.
public enum SubtitleEmbeddingExporter {
    @MainActor
    public static func export(item: TaskMediaItem, kind: SRTOutputKind, to destination: URL,
                              languageTag: String = "und", allowOverwrite: Bool = false,
                              mediaStore: LocalMediaStore = .shared, inspector: MediaInspector = .shared,
                              progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }) async throws {
        guard item.kind == .video else { throw SubtitleEmbeddingError.videoRequired }
        guard let identity = item.media,
              let bookmark = try await mediaStore.resolve(projectID: item.id, identity: identity) else { throw SubtitleEmbeddingError.missingMedia }
        let access = bookmark.url.startAccessingSecurityScopedResource()
        defer { if access { bookmark.url.stopAccessingSecurityScopedResource() } }
        let inspection = try await inspector.inspect(bookmark.url)
        guard identity.matchesContent(of: try inspection.identity(audioTrackID: identity.audioTrackID)) else { throw MediaAccessError.fileChanged }
        let sourceURL = bookmark.url
        let work = Task.detached(priority: .utility) {
            try await remux(item: item, identity: identity, sourceURL: sourceURL, kind: kind,
                            destination: destination, languageTag: languageTag,
                            allowOverwrite: allowOverwrite, progress: progress)
        }
        try await withTaskCancellationHandler {
            try await work.value
        } onCancel: { work.cancel() }
    }

    /// Owns the reader/writer and file publication off the main actor for the full export lifetime.
    private static func remux(item: TaskMediaItem, identity: MediaIdentity, sourceURL: URL,
                              kind: SRTOutputKind, destination: URL, languageTag: String,
                              allowOverwrite: Bool, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        let cues = try SubtitleCue.clampedToMedia(item.cues, media: identity)
        guard !cues.isEmpty else { throw SubtitleExportError.emptyCues }
        let texts = try cues.map { try SubtitleExporter.subtitleText(for: $0, kind: kind) }
        guard destination.isFileURL, destination.pathExtension.lowercased() == "mp4",
              !destination.lastPathComponent.contains("\\"), !destination.lastPathComponent.contains("\0"),
              !destination.deletingPathExtension().lastPathComponent.isEmpty else { throw BurnInError.invalidFileName }
        let manager = FileManager.default
        guard destination.standardizedFileURL.resolvingSymlinksInPath() != sourceURL.standardizedFileURL.resolvingSymlinksInPath() else { throw BurnInError.sourceIsOutput }
        if manager.fileExists(atPath: destination.path) {
            let source = try manager.attributesOfItem(atPath: sourceURL.path)
            let target = try manager.attributesOfItem(atPath: destination.path)
            if source[.systemNumber] as? NSNumber == target[.systemNumber] as? NSNumber,
               source[.systemFileNumber] as? NSNumber == target[.systemFileNumber] as? NSNumber { throw BurnInError.sourceIsOutput }
            guard allowOverwrite else { throw BurnInError.fileAlreadyExists }
        }
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        guard let video = try await asset.loadTracks(withMediaType: .video).first,
              let audio = try await asset.loadTracks(withMediaType: .audio).first(where: { $0.trackID == identity.audioTrackID }) else { throw BurnInError.videoRequired }
        let size = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let displaySize = CGRect(origin: .zero, size: size).applying(transform).standardized.size
        let videoRange = try await video.load(.timeRange)
        let audioRange = try await audio.load(.timeRange)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID()).partial.mp4")
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
        let videoTimeScale = try await video.load(.naturalTimeScale)
        let audioTimeScale = try await audio.load(.naturalTimeScale)
        writer.movieTimeScale = CMTimeAdd(CMTime(value: 1, timescale: videoTimeScale),
            CMTime(value: 1, timescale: audioTimeScale)).timescale
        var pairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for track in [video, audio] {
            let formats = try await track.load(.formatDescriptions)
            guard let format = formats.first else { throw SubtitleEmbeddingError.unsupportedFormat }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: format)
            if track.mediaType == .video { input.transform = transform; input.mediaTimeScale = videoTimeScale }
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(output), writer.canAdd(input) else { throw SubtitleEmbeddingError.unsupportedFormat }
            reader.add(output); writer.add(input); pairs.append((output, input))
        }
        let format = try textFormat(size: displaySize)
        let subtitles = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: format)
        subtitles.mediaTimeScale = 1000
        subtitles.extendedLanguageTag = languageTag
        subtitles.naturalSize = CGSize(width: displaySize.width, height: max(1, displaySize.height * 0.15))
        guard writer.canAdd(subtitles) else { throw SubtitleEmbeddingError.unsupportedFormat }
        writer.add(subtitles)
        // Explicit empty samples clear captions in gaps and before the first cue.
        var samples: [CMSampleBuffer] = []
        var previousEnd: Int64 = 0
        for (cue, text) in zip(cues, texts) {
            if cue.startMilliseconds > previousEnd {
                samples.append(try textSample("", start: previousEnd, end: cue.startMilliseconds, format: format))
            }
            samples.append(try textSample(text, start: cue.startMilliseconds, end: cue.endMilliseconds, format: format))
            previousEnd = cue.endMilliseconds
        }
        if previousEnd < identity.durationMilliseconds {
            samples.append(try textSample("", start: previousEnd, end: identity.durationMilliseconds, format: format))
        }
        do {
            await progress(0)
            try Task.checkCancellation()
            guard writer.startWriting() else { throw writer.error ?? SubtitleEmbeddingError.unsupportedFormat }
            writer.startSession(atSourceTime: .zero)
            guard reader.startReading() else { throw reader.error ?? SubtitleEmbeddingError.unsupportedFormat }
            var ended = Set<Int>()
            var subtitleIndex = 0
            let clock = ContinuousClock()
            var lastPublication = clock.now
            var lastProgress: Double = 0
            var audioPriming = CMTime.zero
            var audioStarted = false
            while ended.count < pairs.count || subtitleIndex < samples.count {
                try Task.checkCancellation()
                var advanced = false
                for (index, pair) in pairs.enumerated() where !ended.contains(index) && pair.1.isReadyForMoreMediaData {
                    if let sample = pair.0.copyNextSampleBuffer() {
                        // Reader edit/drain markers are not encoded media samples.
                        if CMSampleBufferGetNumSamples(sample) == 0 { advanced = true; continue }
                        if index == 1, !audioStarted,
                           let format = CMSampleBufferGetFormatDescription(sample),
                           CMFormatDescriptionGetMediaSubType(format) == kAudioFormatMPEG4AAC {
                            if let trim = CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart, attachmentModeOut: nil) {
                                audioPriming = CMTimeAdd(audioPriming, CMTimeMakeFromDictionary(trim as! CFDictionary))
                            }
                            audioStarted = CMSampleBufferGetOutputDuration(sample) > .zero
                        }
                        guard pair.1.append(sample) else { throw writer.error ?? SubtitleEmbeddingError.invalidOutput }
                        if index == 0 {
                            lastProgress = max(lastProgress, min(0.99, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration.seconds))
                            if lastPublication.duration(to: clock.now) >= .milliseconds(200) {
                                await progress(lastProgress)
                                lastPublication = clock.now
                            }
                        }
                    } else { pair.1.markAsFinished(); ended.insert(index) }
                    advanced = true
                }
                if subtitleIndex < samples.count, subtitles.isReadyForMoreMediaData {
                    guard subtitles.append(samples[subtitleIndex]) else { throw writer.error ?? SubtitleEmbeddingError.invalidOutput }
                    subtitleIndex += 1
                    if subtitleIndex == samples.count { subtitles.markAsFinished() }
                    advanced = true
                }
                guard writer.status == .writing else { throw writer.error ?? SubtitleEmbeddingError.invalidOutput }
                if !advanced { try await Task.sleep(for: .milliseconds(5)) }
            }
            guard reader.status == .completed else { throw reader.error ?? SubtitleEmbeddingError.invalidOutput }
            // Track edits can outlast the asset duration; ending at the movie time drops tail packets.
            writer.endSession(atSourceTime: CMTimeMaximum(duration, CMTimeMaximum(videoRange.end, audioRange.end)))
            await SubtitleEmbeddingFinalization(writer: writer).wait()
            try Task.checkCancellation()
            guard writer.status == .completed else { throw writer.error ?? SubtitleEmbeddingError.invalidOutput }
            if audioPriming > .zero {
                try SubtitleEmbeddingAudioTiming.preserveImplicitPriming(audioPriming, from: sourceURL, audioTrackID: audio.trackID, in: temporary)
            }
            let result = AVURLAsset(url: temporary)
            let resultAudio = try await result.loadTracks(withMediaType: .audio)
            let resultVideo = try await result.loadTracks(withMediaType: .video)
            let resultSubtitles = try await result.loadTracks(withMediaType: .subtitle)
            guard resultAudio.count == 1, resultVideo.count == 1, resultSubtitles.count == 1,
                  let outputAudio = resultAudio.first, let outputVideo = resultVideo.first else { throw SubtitleEmbeddingError.invalidOutput }
            let actualDuration = try await result.load(.duration)
            // Container/codec time scales naturally differ by a frame; reject unusable output,
            // not millisecond-level remux rounding. The writer keeps every source packet.
            let expectedDuration = max(duration.seconds, videoRange.end.seconds, audioRange.end.seconds)
            guard actualDuration.seconds.isFinite, actualDuration.seconds > 0,
                  abs(actualDuration.seconds - expectedDuration) < 0.5,
                  try await outputAudio.load(.isDecodable),
                  try await outputVideo.load(.isDecodable) else { throw SubtitleEmbeddingError.invalidOutput }
            try Task.checkCancellation()
            if manager.fileExists(atPath: destination.path) {
                guard allowOverwrite else { throw BurnInError.fileAlreadyExists }
                _ = try manager.replaceItemAt(destination, withItemAt: temporary)
            } else { try manager.moveItem(at: temporary, to: destination) }
            await progress(1)
        } catch {
            reader.cancelReading(); writer.cancelWriting()
            if manager.fileExists(atPath: temporary.path) {
                do { try manager.removeItem(at: temporary) }
                catch let cleanup { throw SubtitleEmbeddingError.failure(String(localized: "\(error.localizedDescription)；临时文件清理失败：\(cleanup.localizedDescription)", bundle: voxlineLocalizationBundle)) }
            }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private static func textFormat(size: CGSize) throws -> CMFormatDescription {
        let color: [String: Any] = [kCMTextFormatDescriptionColor_Red as String: 255,
            kCMTextFormatDescriptionColor_Green as String: 255, kCMTextFormatDescriptionColor_Blue as String: 255,
            kCMTextFormatDescriptionColor_Alpha as String: 255]
        let extensions: [String: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags as String: 0,
            kCMTextFormatDescriptionExtension_HorizontalJustification as String: 1,
            kCMTextFormatDescriptionExtension_VerticalJustification as String: -1,
            kCMTextFormatDescriptionExtension_BackgroundColor as String: [
                kCMTextFormatDescriptionColor_Red as String: 0, kCMTextFormatDescriptionColor_Green as String: 0,
                kCMTextFormatDescriptionColor_Blue as String: 0, kCMTextFormatDescriptionColor_Alpha as String: 0],
            kCMTextFormatDescriptionExtension_DefaultTextBox as String: [
                kCMTextFormatDescriptionRect_Top as String: 0, kCMTextFormatDescriptionRect_Left as String: 0,
                kCMTextFormatDescriptionRect_Bottom as String: min(32767, Int(max(1, size.height * 0.15))),
                kCMTextFormatDescriptionRect_Right as String: min(32767, Int(size.width))],
            kCMTextFormatDescriptionExtension_DefaultStyle as String: [
                kCMTextFormatDescriptionStyle_StartChar as String: 0, kCMTextFormatDescriptionStyle_EndChar as String: 0,
                kCMTextFormatDescriptionStyle_Font as String: 1, kCMTextFormatDescriptionStyle_FontFace as String: 0,
                kCMTextFormatDescriptionStyle_FontSize as String: 24, kCMTextFormatDescriptionStyle_ForegroundColor as String: color],
            kCMTextFormatDescriptionExtension_FontTable as String: ["1": "Arial"]]
        var format: CMFormatDescription?
        guard CMFormatDescriptionCreate(allocator: kCFAllocatorDefault, mediaType: kCMMediaType_Subtitle,
            mediaSubType: kCMSubtitleFormatType_3GText, extensions: extensions as CFDictionary,
            formatDescriptionOut: &format) == noErr, let format else { throw SubtitleEmbeddingError.unsupportedFormat }
        return format
    }

    private static func textSample(_ text: String, start: Int64, end: Int64, format: CMFormatDescription) throws -> CMSampleBuffer {
        let bytes = Data(text.utf8)
        guard bytes.count <= Int(UInt16.max) else { throw SubtitleEmbeddingError.invalidText }
        var length = UInt16(bytes.count).bigEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }; data.append(bytes)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block) == noErr, let block else {
            throw SubtitleEmbeddingError.invalidText
        }
        let copied = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: end - start, timescale: 1000),
            presentationTimeStamp: CMTime(value: start, timescale: 1000), decodeTimeStamp: .invalid)
        var size = data.count
        var sample: CMSampleBuffer?
        guard copied == noErr, CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { throw SubtitleEmbeddingError.invalidText }
        return sample
    }
}

/// Serializes native finish/cancel calls. Cancellation resumes only after cancelWriting has stopped
/// the writer, so temporary-file cleanup cannot race a still-running native finalization.
final class SubtitleEmbeddingFinalization: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let queue = DispatchQueue(label: "Voxline.SubtitleEmbedding.Finalization")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false
    private var cancelled = false

    init(writer: AVAssetWriter) { self.writer = writer }

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let alreadyFinished = lock.withLock {
                    if finished { return true }
                    self.continuation = continuation
                    return false
                }
                if alreadyFinished { continuation.resume() }
                else {
                    queue.async {
                        guard !self.lock.withLock({ self.cancelled }) else { return }
                        self.writer.finishWriting { self.complete(cancelled: false) }
                    }
                }
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        let shouldCancel = lock.withLock {
            guard !finished, !cancelled else { return false }
            cancelled = true
            return true
        }
        guard shouldCancel else { return }
        queue.async {
            self.writer.cancelWriting()
            self.complete(cancelled: true)
        }
    }

    private func complete(cancelled: Bool) {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard !finished, cancelled || !self.cancelled else { return nil }
            finished = true
            let waiting = continuation
            continuation = nil
            return waiting
        }
        waiting?.resume()
    }

}
