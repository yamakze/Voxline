@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import Testing
import VoxlineCore
@testable import VoxlineMedia

@Suite("Native subtitle burn-in", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct SubtitleBurnInTests {
    @Test func longDialogueFitsPreviewAndExportsWithoutClippingTheSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalMediaStore(directory: directory.appendingPathComponent("access"))
        let inspector = MediaInspector()
        var item = try await fixture(store: store, inspector: inspector, directory: directory)
        try item.cues[0].replaceSourceText(with: String(repeating: "Very long dialogue with a complete ending. ", count: 30))
        item.cues[0].translation = .succeeded(text: String(repeating: "完整长句字幕，自动缩小字号。", count: 30), sourceRevision: 1)
        let plan = try await SubtitleBurnInExporter.composition(for: item, options: BurnInOptions(), mediaStore: store, inspector: inspector)
        defer { plan.releaseAccess() }
        let before = try await plan.preview(atMilliseconds: 500)
        let during = try await plan.preview(atMilliseconds: 1500)
        #expect(try Self.pixels(before) != Self.pixels(during))
        let destination = directory.appendingPathComponent("long.mp4")
        try await SubtitleBurnInExporter.export(plan, to: destination) { _ in }
        let output = try await inspector.inspect(destination)
        #expect(output.durationMilliseconds >= 3900)
        #expect(output.audioTracks.count == 1)
    }
    private var sourceURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VoxlineMediaTests/Fixtures/multi-audio.mov")
    }

    private func fixture(store: LocalMediaStore, inspector: MediaInspector, directory: URL,
                         rotated: Bool = false, repeatCount: Int = 4, colorPrimaries: String? = nil) async throws -> TaskMediaItem {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("input.mov")
        let asset = AVURLAsset(url: sourceURL)
        let composition = AVMutableComposition()
        for source in try await asset.loadTracks(withMediaType: .video) + asset.loadTracks(withMediaType: .audio) {
            let track = try #require(composition.addMutableTrack(withMediaType: source.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid))
            let range = try await source.load(.timeRange)
            for index in 0..<repeatCount { try track.insertTimeRange(range, of: source, at: CMTime(value: Int64(index), timescale: 1)) }
            if source.mediaType == .video {
                let size = try await source.load(.naturalSize)
                track.preferredTransform = rotated ? CGAffineTransform(a: 0, b: 2, c: -1, d: 0, tx: size.height, ty: 0)
                    : try await source.load(.preferredTransform)
            }
        }
        let session = try #require(AVAssetExportSession(asset: composition,
            presetName: colorPrimaries == nil ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality))
        if let colorPrimaries {
            let videoComposition = try await AVMutableVideoComposition.videoComposition(with: composition) { request in
                request.finish(with: request.sourceImage.cropped(to: CGRect(origin: .zero, size: request.renderSize)), context: nil)
            }
            videoComposition.colorPrimaries = colorPrimaries
            videoComposition.colorTransferFunction = kCVImageBufferTransferFunction_ITU_R_709_2 as String
            videoComposition.colorYCbCrMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
            session.videoComposition = videoComposition
        }
        try await session.export(to: url, as: .mov)
        let inspection = try await inspector.inspect(url)
        let identity = try inspection.identity(audioTrackID: #require(inspection.audioTracks.last).id)
        var cue = try SubtitleCue(id: UUID(), startMilliseconds: 1000, endMilliseconds: 2000, sourceText: "Hello\nVoxline")
        cue.translation = .succeeded(text: "你好\n字幕", sourceRevision: cue.sourceRevision)
        let item = TaskMediaItem(title: "Burn-in test", kind: .video, source: .localFile(fileName: identity.fileName),
                                 media: identity, status: .completed, cues: [cue])
        try await store.save(mediaID: item.id, identity: identity, url: url)
        return item
    }

    nonisolated private static func pixels(_ image: CGImage) throws -> [UInt8] {
        var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try result.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return result
    }

    @Test func actualExportKeepsSelectedAudioTimingGeometryCodecAndDrawsOnlyActiveSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalMediaStore(directory: directory.appendingPathComponent("access"))
        let inspector = MediaInspector()
        var item = try await fixture(store: store, inspector: inspector, directory: directory)
        var next = try SubtitleCue(id: UUID(), startMilliseconds: 2000, endMilliseconds: 2400, sourceText: "Next cue")
        next.translation = .succeeded(text: "下一句", sourceRevision: next.sourceRevision)
        item.cues.append(next)
        var options = BurnInOptions()
        options.fontSize = 48
        let plan = try await SubtitleBurnInExporter.composition(for: item, options: options, mediaStore: store, inspector: inspector)
        defer { plan.releaseAccess() }
        let audio = try #require(try await plan.asset.loadTracks(withMediaType: .audio).first)
        let segments = try await audio.load(.segments)
        #expect((segments.first as? AVCompositionTrackSegment)?.sourceTrackID == item.media?.audioTrackID)
        let before = try await plan.preview(atMilliseconds: 500)
        let during = try await plan.preview(atMilliseconds: 1500)
        let boundary = try await plan.preview(atMilliseconds: 2000)
        let second = try await plan.preview(atMilliseconds: 2250)
        let after = try await plan.preview(atMilliseconds: 2500)
        let repeated = try await plan.preview(atMilliseconds: 1500)
        let compact = try await plan.preview(atMilliseconds: 1500, maximumSize: CGSize(width: 16, height: 16))
        #expect(compact.width <= 16 && compact.height <= 16)
        #expect(compact.width < during.width || compact.height < during.height)
        var secondOnly = item
        secondOnly.cues = [next]
        let secondPlan = try await SubtitleBurnInExporter.composition(for: secondOnly, options: options, mediaStore: store, inspector: inspector)
        defer { secondPlan.releaseAccess() }
        let referenceBoundary = try await secondPlan.preview(atMilliseconds: 2000)
        #expect(try Self.pixels(boundary) == Self.pixels(referenceBoundary))
        #expect(try Self.pixels(during) != Self.pixels(second))
        #expect(try Self.pixels(during) == Self.pixels(repeated))
        #expect(before.width == during.width && before.height == during.height)
        #expect(try Self.pixels(before) != Self.pixels(during))
        #expect(try Self.pixels(before) == Self.pixels(after))
        let destination = directory.appendingPathComponent("output.mp4")
        var progress: [Double] = []
        try await SubtitleBurnInExporter.export(plan, to: destination) { progress.append($0) }
        #expect(progress.last == 1)
        let exported = try await inspector.inspect(destination)
        #expect(exported.audioTracks.count == 1)
        #expect(abs(exported.durationMilliseconds - 4000) < 100)
        let asset = AVURLAsset(url: destination)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let format = try #require(try await video.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264)
        #expect(try await video.load(.naturalSize) == plan.renderSize)
        #expect(try await video.load(.preferredTransform) == .identity)
        #expect(abs(try await video.load(.nominalFrameRate) - Float(1 / plan.videoComposition.frameDuration.seconds)) < 0.01)
        let outputAudioTracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(outputAudioTracks.count == 1)
        let outputAudioRange = try await #require(outputAudioTracks.first).load(.timeRange)
        let inputAudioRange = try await audio.load(.timeRange)
        #expect(abs(outputAudioRange.start.seconds - inputAudioRange.start.seconds) < 0.001)
        #expect(abs(outputAudioRange.end.seconds - inputAudioRange.end.seconds) < 0.001)
        let outputBefore = try await Self.outputFrame(destination, milliseconds: 500)
        let outputDuring = try await Self.outputFrame(destination, milliseconds: 1500)
        let outputAfter = try await Self.outputFrame(destination, milliseconds: 2500)
        #expect(try Self.pixels(outputBefore) != Self.pixels(outputDuring))
        // Lossy inter-frame compression can alter pixels slightly, even for identical input frames.
        let beforePixels = try Self.pixels(outputBefore)
        let afterPixels = try Self.pixels(outputAfter)
        let outsideDifference = zip(beforePixels, afterPixels).map { abs(Int($0) - Int($1)) }.reduce(0, +)
        #expect(Double(outsideDifference) / Double(beforePixels.count) < 5)
        let existing = try Data(contentsOf: destination)
        await #expect(throws: BurnInError.fileAlreadyExists) {
            try await SubtitleBurnInExporter.export(plan, to: destination) { _ in }
        }
        #expect(try Data(contentsOf: destination) == existing)
        try await SubtitleBurnInExporter.export(plan, to: destination, allowOverwrite: true) { _ in }
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let cancelled = Task { @MainActor in
            try Task.checkCancellation()
            try await SubtitleBurnInExporter.export(plan, to: directory.appendingPathComponent("cancelled.mp4")) { _ in }
        }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancelled.mp4").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.contains("partial") })
    }

    @Test func portraitOutputMatchesPreviewAndCancellingDuringExportPreservesExistingFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalMediaStore(directory: directory.appendingPathComponent("access"))
        let inspector = MediaInspector()
        var item = try await fixture(store: store, inspector: inspector, directory: directory, rotated: true, repeatCount: 600)
        item.cues = try SubtitleTimeOffset.shifted(item.cues, by: 1000, withinDuration: 600000)
        var options = BurnInOptions()
        options.kind = .translation
        options.codec = .hevc
        let plan = try await SubtitleBurnInExporter.composition(for: item, options: options, mediaStore: store, inspector: inspector)
        defer { plan.releaseAccess() }
        let preview = try await plan.preview(atMilliseconds: 2500)
        #expect(preview.height > preview.width)
        let destination = directory.appendingPathComponent("portrait.mp4")
        try await SubtitleBurnInExporter.export(plan, to: destination) { _ in }
        let image = try await Self.outputFrame(destination, milliseconds: 2500)
        #expect(image.width == preview.width && image.height == preview.height)
        let asset = AVURLAsset(url: destination)
        let format = try #require(try await asset.loadTracks(withMediaType: .video).first?.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
        let before = try Data(contentsOf: destination)
        var exportTask: Task<Void, Error>?
        var sawExportProgress = false
        exportTask = Task { @MainActor in
            try await SubtitleBurnInExporter.export(plan, to: destination, allowOverwrite: true) { value in
                if value < 1 { sawExportProgress = true; exportTask?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { try await exportTask?.value }
        #expect(sawExportProgress)
        #expect(try Data(contentsOf: destination) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.contains("partial") })
    }

    @Test func translatedSnapshotValidationAndOriginalFileProtection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalMediaStore(directory: directory)
        let inspector = MediaInspector()
        var item = try await fixture(store: store, inspector: inspector, directory: directory)
        try item.cues[0].replaceSourceText(with: "Edited original")
        let translatedPlan = try await SubtitleBurnInExporter.composition(for: item, options: BurnInOptions(), mediaStore: store, inspector: inspector)
        translatedPlan.releaseAccess()
        var options = BurnInOptions()
        options.kind = .source
        let plan = try await SubtitleBurnInExporter.composition(for: item, options: options, mediaStore: store, inspector: inspector)
        defer { plan.releaseAccess() }
        let hardlink = directory.appendingPathComponent("source.mp4")
        try FileManager.default.linkItem(at: plan.sourceURL, to: hardlink)
        await #expect(throws: BurnInError.sourceIsOutput) {
            try await SubtitleBurnInExporter.export(plan, to: hardlink, allowOverwrite: true) { _ in }
        }
        #expect(try Data(contentsOf: hardlink) == Data(contentsOf: plan.sourceURL))
        item = TaskMediaItem(title: item.title, kind: .audio, source: item.source, media: item.media, cues: item.cues)
        await #expect(throws: BurnInError.videoRequired) {
            _ = try await SubtitleBurnInExporter.composition(for: item, options: options, mediaStore: store, inspector: inspector)
        }
    }

    nonisolated private static func outputFrame(_ url: URL, milliseconds: Int64) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(value: milliseconds, timescale: 1000)).image
    }

    @Test func wideGamutTaggedVideoIsRejectedBeforeCreatingBurnInComposition() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalMediaStore(directory: directory.appendingPathComponent("access"))
        let inspector = MediaInspector()
        let item = try await fixture(store: store, inspector: inspector, directory: directory,
                                     colorPrimaries: kCVImageBufferColorPrimaries_P3_D65 as String)
        let source = AVURLAsset(url: directory.appendingPathComponent("input.mov"))
        let video = try #require(try await source.loadTracks(withMediaType: .video).first)
        let format = try #require(try await video.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
            == kCVImageBufferColorPrimaries_P3_D65 as String)
        await #expect(throws: BurnInError.unsupportedColor) {
            _ = try await SubtitleBurnInExporter.composition(for: item, options: BurnInOptions(), mediaStore: store, inspector: inspector)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXLINE_BURN_IN_SAMPLE"] != nil))
    func realSampleProducesThreeSubtitledVideosFromReviewedText() async throws {
        let environment = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: try #require(environment["VOXLINE_BURN_IN_SAMPLE"]))
        let document = URL(fileURLWithPath: try #require(environment["VOXLINE_BURN_IN_TASK"]))
        let directory = URL(fileURLWithPath: try #require(environment["VOXLINE_BURN_IN_OUTPUT"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let task = try TaskDocumentCodec.decode(Data(contentsOf: document))
        let reviewed = try #require(task.items.first)
        let inspector = MediaInspector()
        let inspection = try await inspector.inspect(source)
        let identity = try inspection.identity(audioTrackID: #require(inspection.audioTracks.first).id)
        let cues = reviewed.cues.filter { $0.endMilliseconds <= identity.durationMilliseconds }
        let inputAsset = AVURLAsset(url: source)
        let inputAudio = try #require(try await inputAsset.loadTracks(withMediaType: .audio)
            .first { $0.trackID == identity.audioTrackID })
        let inputAudioRange = try await inputAudio.load(.timeRange)
        #expect(!cues.isEmpty && cues.allSatisfy(\.hasTranslation))
        let item = TaskMediaItem(title: "S001 已校对短视频", kind: .video, source: .localFile(fileName: source.lastPathComponent),
                                 media: identity, status: .completed, cues: cues)
        let store = LocalMediaStore(directory: directory.appendingPathComponent("access"))
        try await store.save(mediaID: item.id, identity: identity, url: source)
        var results: [[String: String]] = []
        for kind in [SRTOutputKind.source, .translation, .bilingual] {
            var options = BurnInOptions()
            options.kind = kind
            let plan = try await SubtitleBurnInExporter.composition(for: item, options: options, mediaStore: store, inspector: inspector)
            defer { plan.releaseAccess() }
            let filename = "S001-\(kind.rawValue).mp4"
            let output = directory.appendingPathComponent(filename)
            let started = ContinuousClock.now
            try await SubtitleBurnInExporter.export(plan, to: output, allowOverwrite: true) { _ in }
            let elapsed = started.duration(to: .now)
            let result = try await inspector.inspect(output)
            #expect(abs(result.durationMilliseconds - inspection.durationMilliseconds) < 100)
            #expect(result.audioTracks.count == 1)
            let exported = AVURLAsset(url: output)
            let outputAudio = try #require(try await exported.loadTracks(withMediaType: .audio).first)
            let outputAudioRange = try await outputAudio.load(.timeRange)
            #expect(abs(outputAudioRange.start.seconds - inputAudioRange.start.seconds) < 0.001)
            #expect(abs(outputAudioRange.end.seconds - inputAudioRange.end.seconds) < 0.001)
            let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
            results.append(["output":filename,"elapsed":String(describing: elapsed),"bytes":String(describing:attributes[.size]!),
                            "frameSize":"\(plan.renderSize)","frameDuration":"\(plan.videoComposition.frameDuration.seconds)","cues":"\(cues.count)"])
        }
        try JSONEncoder().encode(results).write(to: directory.appendingPathComponent("metrics.json"), options: .atomic)
        var sampleItem = item
        sampleItem.status = .pending
        var sampleTask = ProcessingTask(title: "VXL-039 S001 烧录验收", items: [sampleItem])
        try sampleTask.recordStart()
        sampleTask.items[0].status = .completed
        try TaskDocumentCodec.encode(sampleTask).write(to: directory.appendingPathComponent("S001.voxline"),options: .atomic)
    }
}
