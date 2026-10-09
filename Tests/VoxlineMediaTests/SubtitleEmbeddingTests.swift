@preconcurrency import AVFoundation
import Foundation
import CryptoKit
import Testing
import VoxlineCore
@testable import VoxlineMedia

@Suite("Native embedded subtitles", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct SubtitleEmbeddingTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXLINE_EMBEDDING_TASK"] != nil))
    func realReviewedTaskExportsEmbeddedSubtitles() async throws {
        let taskURL = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VOXLINE_EMBEDDING_TASK"]))
        let source = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VOXLINE_EMBEDDING_MEDIA"]))
        let task = try TaskDocumentCodec.decode(Data(contentsOf: taskURL))
        let item = try #require(task.items.first)
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/embedding-validation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existingOutput = ProcessInfo.processInfo.environment["VOXLINE_EMBEDDING_OUTPUT"]
        let output = existingOutput.map { URL(fileURLWithPath: $0) } ?? directory.appendingPathComponent("reviewed-bilingual.mp4")
        if existingOutput == nil {
            let store = LocalMediaStore(directory: directory.appendingPathComponent("bookmarks"))
            try await store.save(projectID: item.id, identity: #require(item.media), url: source)
            try await SubtitleEmbeddingExporter.export(item: item, kind: .bilingual,
                to: output, languageTag: "zh-Hans", allowOverwrite: true, mediaStore: store)
        }
        let original = AVURLAsset(url: source)
        let result = AVURLAsset(url: output)
        for type in [AVMediaType.video, .audio] {
            let beforeTrack = try #require(try await original.loadTracks(withMediaType: type).first {
                type == .video || $0.trackID == item.media?.audioTrackID
            })
            let afterTrack = try #require(try await result.loadTracks(withMediaType: type).first)
            let before = try compressedFingerprint(asset: original, track: beforeTrack)
            let after = try compressedFingerprint(asset: result, track: afterTrack)
            #expect(before.count == after.count)
            #expect(before.bytes == after.bytes)
            #expect(before.timing == after.timing)
            let beforeRange = try await beforeTrack.load(.timeRange), afterRange = try await afterTrack.load(.timeRange)
            #expect(abs(beforeRange.start.seconds - afterRange.start.seconds) < 0.001)
            #expect(abs(beforeRange.end.seconds - afterRange.end.seconds) < 0.001)
            print("EMBEDDED_REAL_MEDIA \(type.rawValue) packets=\(after.count) start=\(afterRange.start.seconds) end=\(afterRange.end.seconds) payloadAndTimingUnchanged=\(before.bytes == after.bytes && before.timing == after.timing)")
        }
        let subtitles = try #require(try await result.loadTracks(withMediaType: .subtitle).first)
        let captions = try encodedSamples(asset: result, track: subtitles).filter { $0.0 != Data([0, 0]) }
        #expect(captions.count == item.cues.count)
        for (caption, cue) in zip(captions, item.cues) {
            #expect(caption.1 == CMTime(value: cue.startMilliseconds, timescale: 1000))
            #expect(caption.2 == CMTime(value: cue.endMilliseconds - cue.startMilliseconds, timescale: 1000))
            let length = Int(caption.0[0]) * 256 + Int(caption.0[1])
            #expect(String(data: caption.0.dropFirst(2).prefix(length), encoding: .utf8) == (try SubtitleExporter.subtitleText(for: cue, kind: .bilingual)))
        }
        #expect(try await result.loadMediaSelectionGroup(for: .legible)?.allowsEmptySelection == true)
    }

    private func compressedFingerprint(asset: AVAsset, track: AVAssetTrack) throws -> (count: Int, bytes: SHA256.Digest, timing: SHA256.Digest) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? SubtitleEmbeddingError.invalidOutput }
        var bytes = SHA256(), timingHash = SHA256(), count = 0
        while let sample = output.copyNextSampleBuffer() {
            let sampleCount = CMSampleBufferGetNumSamples(sample)
            if sampleCount == 0 { continue }
            count += sampleCount
            let block = try #require(CMSampleBufferGetDataBuffer(sample))
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            #expect(status == noErr); bytes.update(data: data)
            for index in 0..<sampleCount {
                var timing = CMSampleTimingInfo()
                #expect(CMSampleBufferGetSampleTimingInfo(sample, at: index, timingInfoOut: &timing) == noErr)
                for time in [timing.presentationTimeStamp, timing.duration] {
                    var value = CMTimeConvertScale(time, timescale: 600_000_000, method: .default).value.bigEndian
                    timingHash.update(data: withUnsafeBytes(of: &value) { Data($0) })
                }
            }
        }
        #expect(reader.status == .completed)
        return (count, bytes.finalize(), timingHash.finalize())
    }

    private func fixture(_ directory: URL) async throws -> (TaskMediaItem, LocalMediaStore, URL) {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/multi-audio.mov")
        let store = LocalMediaStore(directory: directory.appendingPathComponent("bookmarks"))
        let inspection = try await MediaInspector.shared.inspect(source)
        let identity = try inspection.identity(audioTrackID: #require(inspection.audioTracks.last).id)
        var cue = try SubtitleCue(id: UUID(), startMilliseconds: 100, endMilliseconds: 600, sourceText: "Hello\nVoxline")
        cue.translation = .succeeded(text: "你好\n字幕", sourceRevision: cue.sourceRevision)
        let item = TaskMediaItem(title: "Embedded test", kind: .video, source: .localFile(fileName: identity.fileName),
            media: identity, status: .completed, cues: [cue])
        try await store.save(projectID: item.id, identity: identity, url: source)
        return (item, store, source)
    }

    private func encodedSamples(asset: AVAsset, track: AVAssetTrack) throws -> [(Data, CMTime, CMTime)] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? SubtitleEmbeddingError.invalidOutput }
        var result: [(Data, CMTime, CMTime)] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            let block = try #require(CMSampleBufferGetDataBuffer(sample))
            let size = CMBlockBufferGetDataLength(block)
            var data = Data(count: size)
            let status = data.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!)
            }
            #expect(status == noErr)
            result.append((data, CMSampleBufferGetPresentationTimeStamp(sample), CMSampleBufferGetDuration(sample)))
        }
        #expect(reader.status == .completed)
        return result
    }

    @Test(arguments: [SRTOutputKind.source, .translation, .bilingual])
    func nativeMuxKeepsEncodedMediaAndSelectableUTF8Timings(kind: SRTOutputKind) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (item, store, source) = try await fixture(directory)
        let output = directory.appendingPathComponent("output.mp4")
        var fractions: [Double] = []
        try await SubtitleEmbeddingExporter.export(item: item, kind: kind, to: output, languageTag: "zh-Hans",
            mediaStore: store) { fractions.append($0) }
        #expect(fractions.last == 1)
        let sourceAsset = AVURLAsset(url: source), result = AVURLAsset(url: output)
        let sourceVideo = try #require(try await sourceAsset.loadTracks(withMediaType: .video).first)
        let resultVideo = try #require(try await result.loadTracks(withMediaType: .video).first)
        let sourceAudio = try #require(try await sourceAsset.loadTracks(withMediaType: .audio).first { $0.trackID == item.media?.audioTrackID })
        let resultAudio = try #require(try await result.loadTracks(withMediaType: .audio).first)
        for (a, b) in [(sourceVideo, resultVideo), (sourceAudio, resultAudio)] {
            let before = try encodedSamples(asset: sourceAsset, track: a)
            let after = try encodedSamples(asset: result, track: b)
            #expect(before.map { $0.0 } == after.map { $0.0 })
            #expect(before.map { $0.1 } == after.map { $0.1 })
            #expect(before.map { $0.2 } == after.map { $0.2 })
        }
        #expect(try await resultVideo.load(.preferredTransform) == sourceVideo.load(.preferredTransform))
        let track = try #require(try await result.loadTracks(withMediaType: .subtitle).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMSubtitleFormatType_3GText)
        let samples = try encodedSamples(asset: result, track: track)
        let body = try #require(samples.first { $0.1 == CMTime(value: 100, timescale: 1000) })
        #expect(body.2 == CMTime(value: 500, timescale: 1000))
        let length = Int(body.0[0]) * 256 + Int(body.0[1])
        #expect(String(data: body.0.dropFirst(2).prefix(length), encoding: .utf8) == (try SubtitleExporter.subtitleText(for: item.cues[0], kind: kind)))
        #expect(samples.first?.0 == Data([0, 0]))
        #expect(samples.last?.0 == Data([0, 0]))
        let group = try #require(try await result.loadMediaSelectionGroup(for: .legible))
        let options = group.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
        #expect(options.count == 1 && group.allowsEmptySelection)
        let playerItem = AVPlayerItem(asset: result)
        playerItem.select(options[0], in: group)
        #expect(playerItem.currentMediaSelection.selectedMediaOption(in: group) == options[0])
        playerItem.select(nil, in: group)
        #expect(playerItem.currentMediaSelection.selectedMediaOption(in: group) == nil)
    }

    @Test func nativeFinalizationCancellationCompletesOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = AVURLAsset(url: Bundle.module.url(forResource: "multi-audio", withExtension: "mov", subdirectory: "Fixtures")!)
        let track = try #require(try await source.loadTracks(withMediaType: .audio).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        for attempt in 0..<24 {
            let writer = try AVAssetWriter(outputURL: directory.appendingPathComponent("finish-\(attempt).mov"), fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            writer.add(input)
            #expect(writer.startWriting())
            writer.startSession(atSourceTime: .zero)
            let reader = try AVAssetReader(asset: source)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            #expect(reader.startReading())
            let sample = try #require(output.copyNextSampleBuffer())
            #expect(input.append(sample))
            input.markAsFinished()
            reader.cancelReading()
            let finalization = SubtitleEmbeddingFinalization(writer: writer)
            let work = Task {
                await finalization.wait()
                try Task.checkCancellation()
            }
            if attempt % 2 == 0 { await Task.yield() }
            work.cancel()
            await #expect(throws: CancellationError.self) { try await work.value }
            #expect(writer.status != .writing)
        }
    }

    @Test func protectionCancellationAndStaleTranslationKeepExistingOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (item, store, source) = try await fixture(directory)
        let output = directory.appendingPathComponent("output.mp4")
        let original = Data("existing-output".utf8)
        try original.write(to: output)
        await #expect(throws: BurnInError.fileAlreadyExists) {
            try await SubtitleEmbeddingExporter.export(item: item, kind: .source, to: output, mediaStore: store)
        }
        let link = directory.appendingPathComponent("original.mp4")
        try FileManager.default.linkItem(at: source, to: link)
        await #expect(throws: BurnInError.sourceIsOutput) {
            try await SubtitleEmbeddingExporter.export(item: item, kind: .source, to: link, allowOverwrite: true, mediaStore: store)
        }
        var work: Task<Void, Error>?
        work = Task { @MainActor in
            try await SubtitleEmbeddingExporter.export(item: item, kind: .source, to: output, allowOverwrite: true,
                mediaStore: store) { _ in work?.cancel() }
        }
        let running = try #require(work)
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(try Data(contentsOf: output) == original)
        var stale = item
        stale.cues[0].translation = .pending
        await #expect(throws: SubtitleExportError.incompleteTranslations(1)) {
            try await SubtitleEmbeddingExporter.export(item: stale, kind: .bilingual, to: output, allowOverwrite: true, mediaStore: store)
        }
        #expect(try Data(contentsOf: output) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.contains(".partial.") })
    }
}
