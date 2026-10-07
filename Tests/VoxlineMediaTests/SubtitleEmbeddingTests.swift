@preconcurrency import AVFoundation
import Foundation
import Testing
import VoxlineCore
@testable import VoxlineMedia

@Suite("Native embedded subtitles", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct SubtitleEmbeddingTests {
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
        try stale.cues[0].replaceSourceText(with: "Changed")
        await #expect(throws: SubtitleExportError.incompleteTranslations(1)) {
            try await SubtitleEmbeddingExporter.export(item: stale, kind: .bilingual, to: output, allowOverwrite: true, mediaStore: store)
        }
        #expect(try Data(contentsOf: output) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.contains(".partial.") })
    }
}
