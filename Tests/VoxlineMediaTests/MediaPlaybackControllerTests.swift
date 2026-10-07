import AVFoundation
import Foundation
import Testing
import VoxlineCore
@testable import VoxlineMedia

@Suite("Native playback and shared subtitle timeline", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MediaPlaybackControllerTests {
    private var videoURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VoxlineMediaTests/Fixtures/multi-audio.mov")
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw PlaybackTestError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    nonisolated private static func videoFrameSize(url: URL) async throws -> CGSize {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        let frame = try await generator.image(at: .zero)
        return CGSize(width: frame.image.width, height: frame.image.height)
    }

    private func fixture(at url: URL, inspector: MediaInspector) async throws -> TaskMediaItem {
        let inspection = try await inspector.inspect(url)
        let track = try #require(inspection.audioTracks.last)
        let identity = try inspection.identity(audioTrackID: track.id)
        var first = try SubtitleCue(id: UUID(), startMilliseconds: 0, endMilliseconds: 400, sourceText: "First test subtitle")
        first.translation = .succeeded(text: "第一条测试字幕", sourceRevision: first.sourceRevision)
        var last = try SubtitleCue(id: UUID(), startMilliseconds: 400, endMilliseconds: 1000, sourceText: "Second test subtitle")
        last.translation = .succeeded(text: "第二条测试字幕", sourceRevision: last.sourceRevision)
        return TaskMediaItem(title: "VXL-015 原生播放验证样本", kind: inspection.kind,
                             source: .localFile(fileName: identity.fileName), media: identity,
                             status: .completed, cues: [first, last])
    }

    @Test func realVideoUsesSelectedTrackAndSynchronizesNativeControlsSeekingEndAndRelease() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalMediaStore(directory: directory)
        let inspector = MediaInspector()
        let item = try await fixture(at: videoURL, inspector: inspector)
        try await store.save(projectID: item.id, identity: #require(item.media), url: videoURL)
        let controller = MediaPlaybackController(mediaStore: store, inspector: inspector)
        defer { controller.releaseMedia() }
        await controller.loadMedia(for: item)
        try await waitFor { controller.isReady || controller.errorMessage != nil }
        #expect(controller.errorMessage == nil)
        #expect(controller.isReady)
        #expect(!controller.isLoading)
        #expect(controller.durationSeconds == 1)
        let player = try #require(controller.player)
        let asset = try #require(player.currentItem?.asset)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1)
        let track = try #require(tracks.first as? AVCompositionTrack)
        let segments = try await track.load(.segments)
        #expect((segments.first as? AVCompositionTrackSegment)?.sourceTrackID == item.media?.audioTrackID)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        let dimensions = try await Self.videoFrameSize(url: videoURL)
        #expect(dimensions.width > 0 && dimensions.height > 0)

        controller.seek(toMilliseconds: 400)
        try await waitFor { abs(controller.currentTimeSeconds - 0.4) < 0.01 }
        #expect(controller.activeCue(in: item.cues)?.id == item.cues[1].id)
        controller.seek(to: .nan)
        controller.setRate(.infinity)
        #expect(controller.playbackRate == 1)
        #expect(controller.errorMessage == nil)
        // Native VideoPlayer controls also operate directly on this same AVPlayer.
        player.playImmediately(atRate: 0.5)
        try await waitFor { controller.isPlaying }
        player.pause()
        try await waitFor { !controller.isPlaying && player.timeControlStatus == .paused }
        controller.setRate(2)
        #expect(!controller.isPlaying && player.timeControlStatus == .paused)
        #expect(controller.playbackRate == 2)
        controller.togglePlayPause()
        #expect(player.rate == 2)
        try await waitFor { controller.currentTimeSeconds >= 0.99 && !controller.isPlaying }
        #expect(controller.activeCue(in: item.cues) == nil)
        controller.togglePlayPause()
        #expect(controller.playbackRate == 2)
        try await waitFor { controller.isPlaying && controller.currentTimeSeconds < 0.9 }
        controller.pause()
        try await waitFor { !controller.isPlaying }
        controller.seek(to: 0.2)
        try await waitFor { abs(controller.currentTimeSeconds - 0.2) < 0.01 }
        #expect(controller.formattedCurrentTime == "00:00.200")
        let shifted = try SubtitleTimeOffset.shifted([item.cues[1]], by: -100, withinDuration: 1000)
        controller.seek(to: 0.35)
        try await waitFor { abs(controller.currentTimeSeconds - 0.35) < 0.01 }
        #expect(controller.activeCue(in: item.cues)?.id == item.cues[0].id)
        #expect(controller.activeCue(in: shifted)?.id == item.cues[1].id)
        let playerItem = try #require(player.currentItem)
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: playerItem,
            userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: NSError(domain: "PlaybackTest", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Explicit playback interruption"])])
        try await waitFor { controller.errorMessage != nil }
        #expect(controller.errorMessage == "Explicit playback interruption")
        #expect(!controller.isReady && !controller.isPlaying && controller.isMediaUnavailable)
        controller.releaseMedia()
        player.play()
        try await Task.sleep(for: .milliseconds(80))
        #expect(controller.player == nil && !controller.isReady && !controller.isPlaying)
        #expect(controller.currentTimeSeconds == 0 && controller.durationSeconds == 0)
    }

    @Test func audioPreviewHasNoVideoAndFailuresAndLateLoadCannotReviveReleasedPlayer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inspector = MediaInspector()
        let store = LocalMediaStore(directory: directory.appendingPathComponent("bookmarks"))
        let video = try await fixture(at: videoURL, inspector: inspector)
        let extractor = AudioExtractor(directory: directory.appendingPathComponent("audio"))
        let output = try await extractor.extract(mediaURL: videoURL, mediaID: video.id, identity: #require(video.media))
        let audioURL = try #require(output.chunks.first).localURL
        let audio = try await fixture(at: audioURL, inspector: inspector)
        try await store.save(projectID: audio.id, identity: #require(audio.media), url: audioURL)
        let controller = MediaPlaybackController(mediaStore: store, inspector: inspector)
        defer { controller.releaseMedia() }
        await controller.loadMedia(for: audio)
        try await waitFor { controller.isReady || controller.errorMessage != nil }
        #expect(controller.isReady)
        #expect(try await controller.player?.currentItem?.asset.loadTracks(withMediaType: .video).isEmpty == true)
        let oldPlayer = try #require(controller.player)
        controller.releaseMedia()
        oldPlayer.play()
        try await Task.sleep(for: .milliseconds(80))
        #expect(controller.player == nil && !controller.isPlaying && !controller.isLoading)
        #expect(controller.currentTimeSeconds == 0)
        await controller.loadMedia(for: video) // No bookmark for this item.
        #expect(controller.isMediaUnavailable && !controller.isReady)
        #expect(controller.errorMessage?.contains("未找到") == true)
        try FileManager.default.removeItem(at: audioURL)
        try Data("corrupt media".utf8).write(to: audioURL)
        await controller.loadMedia(for: audio)
        #expect(controller.isMediaUnavailable && !controller.isReady && !controller.isLoading)
        #expect(controller.errorMessage != nil)
        let loading = Task { await controller.loadMedia(for: video) }
        await Task.yield()
        controller.releaseMedia()
        await loading.value
        #expect(controller.player == nil && !controller.isLoading && controller.errorMessage == nil)
    }
}

private enum PlaybackTestError: Error { case timeout }
