import AVFoundation
import Foundation
import Testing
import VoxlineCore
@testable import VoxlineMedia

@Suite("Real timed-text import and overlapping export", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct SubtitleImportMediaTests {
    @Test func embeddedOverlapsRoundTripDisplayIntervalsWithoutChangingSourceCues() async throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/multi-audio.mov")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inspector = MediaInspector()
        let inspected = try await inspector.inspect(source)
        let media = try inspected.identity(audioTrackID: #require(inspected.audioTracks.first).id)
        let cues = try [SubtitleCue(id: UUID(), startMilliseconds: 0, endMilliseconds: 800, sourceText: "First 第一"),
                        SubtitleCue(id: UUID(), startMilliseconds: 200, endMilliseconds: 600, sourceText: "Second 第二")]
        let item = TaskMediaItem(title: "overlap", kind: .video, source: .localFile(fileName: media.fileName), media: media, cues: cues)
        let store = LocalMediaStore(directory: directory.appendingPathComponent("bookmarks"))
        try await store.save(mediaID: item.id, identity: media, url: source)
        let output = directory.appendingPathComponent("overlap.mp4")
        try await SubtitleEmbeddingExporter.export(item: item, kind: .source, to: output, languageTag: "en", mediaStore: store, inspector: inspector)
        let reader = SubtitleImportReader()
        let tracks = try await reader.tracks(in: output)
        #expect(tracks.count == 1 && tracks[0].language == "en")
        let entries = try await reader.readEmbeddedTrack(#require(tracks.first).id, in: output)
        #expect(entries.map(\.text) == ["First 第一", "First 第一\nSecond 第二", "First 第一"])
        #expect(entries.map(\.startMilliseconds) == [0, 200, 600])
        #expect(entries.map(\.endMilliseconds) == [200, 600, 800])
        #expect(item.cues == cues)
        var options = BurnInOptions(); options.kind = .source
        let plan = try await SubtitleBurnInExporter.composition(for: item, options: options, mediaStore: store, inspector: inspector)
        defer { plan.releaseAccess() }
        let frame = try await plan.preview(atMilliseconds: 400)
        let combined = try SubtitleCue(id: UUID(), startMilliseconds: 0, endMilliseconds: 800, sourceText: "First 第一\nSecond 第二")
        var expected = item; expected.cues = [combined]
        let expectedPlan = try await SubtitleBurnInExporter.composition(for: expected, options: options, mediaStore: store, inspector: inspector)
        defer { expectedPlan.releaseAccess() }
        let expectedFrame = try await expectedPlan.preview(atMilliseconds: 400)
        #expect(frame.dataProvider?.data as Data? == expectedFrame.dataProvider?.data as Data?)
        var single = item; single.cues = [cues[0]]
        let singlePlan = try await SubtitleBurnInExporter.composition(for: single, options: options, mediaStore: store, inspector: inspector)
        defer { singlePlan.releaseAccess() }
        let singleFrame = try await singlePlan.preview(atMilliseconds: 400)
        #expect(frame.dataProvider?.data as Data? != singleFrame.dataProvider?.data as Data?)
        let controller = MediaPlaybackController(mediaStore: store, inspector: inspector)
        controller.updateSubtitles(cues)
        #expect(controller.activeSubtitles == [cues[0]])
        controller.updateSubtitles([cues[0], try SubtitleCue(id: UUID(), startMilliseconds: 0, endMilliseconds: 600, sourceText: "Concurrent")])
        #expect(controller.activeSubtitles.count == 2)
        controller.releaseMedia()
    }
}
