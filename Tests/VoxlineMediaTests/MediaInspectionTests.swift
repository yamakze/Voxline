import AVFoundation
import Foundation
import Testing
import VoxlineCore
@testable import VoxlineMedia

@Suite("Native movie inspection")
struct MediaInspectionTests {
    @Test func multipleLanguageTracksKeepExplicitIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await MovieFixture.make(in: directory, withAudio: true)
        let result = try await MediaInspector().inspect(url)
        #expect(result.videoTracks.count == 1)
        #expect(result.audioTracks.count == 2)
        #expect(Set(result.audioTracks.compactMap(\.language)) == ["en", "es"] ||
                Set(result.audioTracks.compactMap(\.language)) == ["eng", "spa"])
        #expect(result.audioTracks.allSatisfy { $0.isDecodable })
        #expect(result.durationMilliseconds == 1000)
        let selected = try #require(result.audioTracks.last)
        #expect(try result.identity(audioTrackID: selected.id).audioTrackID == selected.id)
        #expect(throws: MediaAccessError.invalidAudioTrack) { try result.identity(audioTrackID: 9999) }
        let again = try await MediaInspector().inspect(url)
        #expect(again.sha256 == result.sha256)
        #expect(again.byteCount == result.byteCount)
    }

    @Test func videoWithoutAudioHasAnExplicitFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await MovieFixture.make(in: directory, withAudio: false)
        await #expect(throws: MediaAccessError.noAudio) { try await MediaInspector().inspect(url) }
    }
}

// A generated one-second H.264 / bilingual PCM fixture; tests do not require a video encoder.
enum MovieFixture {
    static func make(in directory: URL, withAudio: Bool) async throws -> URL {
        let source = try #require(Bundle.module.url(forResource: "multi-audio", withExtension: "mov", subdirectory: "Fixtures"))
        let url = directory.appendingPathComponent("sample.mov")
        if withAudio {
            try FileManager.default.copyItem(at: source, to: url)
        } else {
            let asset = AVURLAsset(url: source)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try #require(tracks.first)
            let composition = AVMutableComposition()
            let video = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
            try video.insertTimeRange(try await track.load(.timeRange), of: track, at: .zero)
            let exporter = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
            try await exporter.export(to: url, as: .mov)
        }
        return url
    }
}
