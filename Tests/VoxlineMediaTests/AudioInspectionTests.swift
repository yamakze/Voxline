import AVFoundation
import Foundation
import Testing
import VoxlineCore
@testable import VoxlineMedia

@Suite("Native audio input and inspection reuse")
struct AudioInspectionTests {
    @Test(arguments: ["m4a", "mp3", "wav"])
    func standaloneAudioIsDecodableWithoutVideo(extension ext: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sample.\(ext)")
        try AudioFixture.write(to: url)
        let inspector = MediaInspector()
        let result = try await inspector.inspect(url)
        #expect(result.kind == .audio)
        #expect(result.videoTracks.isEmpty)
        #expect(result.durationMilliseconds >= 900)
        #expect(result.audioTracks.count == 1)
        let track = try #require(result.audioTracks.first)
        #expect(track.isDecodable)
        #expect(!track.codecs.isEmpty)
        let identity = try await inspector.confirm(result, audioTrackID: track.id)
        #expect(identity.sha256 == result.sha256)
        // Decode actual samples rather than relying solely on AVAsset metadata.
        let reader = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 1024))
        try reader.read(into: buffer)
        #expect(buffer.frameLength > 0)
    }

    @Test func changedFileInvalidatesInspectionAndCannotConfirmOldIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sample.wav")
        try AudioFixture.write(to: url)
        let inspector = MediaInspector()
        let selected = try await inspector.inspect(url)
        let track = try #require(selected.audioTracks.first)
        try AudioFixture.write(to: url, frameCount: 32000)
        let changed = try await inspector.inspect(url)
        #expect(changed.byteCount != selected.byteCount)
        #expect(changed.durationMilliseconds == 2000)
        #expect(changed.sha256 != selected.sha256)
        await #expect(throws: MediaAccessError.fileChanged) {
            try await inspector.confirm(selected, audioTrackID: track.id)
        }
        // A same-sized rewrite must also invalidate the cache by modification date.
        try AudioFixture.write(to: url, frameCount: 32000, sample: 0.25)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10_000)],
                                              ofItemAtPath: url.path)
        let rewritten = try await inspector.inspect(url)
        #expect(rewritten.byteCount == changed.byteCount)
        #expect(rewritten.sha256 != changed.sha256)
    }

    @Test func invalidAndUnsupportedAudioFailExplicitly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("broken.wav")
        try Data().write(to: url)
        await #expect(throws: MediaAccessError.invalidFile) { try await MediaInspector().inspect(url) }
        let unsupported = directory.appendingPathComponent("sample.aac")
        #expect(throws: MediaAccessError.unsupportedFormat) { try MediaInspector.kind(of: unsupported) }
        try Data("invalid audio".utf8).write(to: url)
        await #expect(throws: (any Error).self) { try await MediaInspector().inspect(url) }
    }
}

enum AudioFixture {
    static func write(to url: URL, frameCount: AVAudioFrameCount = 16000, sample: Float = 0) throws {
        if url.pathExtension == "mp3" {
            // Generated MPEG-1 Layer III mono silence: 128 kbps / 44.1 kHz, 40 zero-data frames.
            // No third-party recording or encoder is required for this fixture.
            var data = Data()
            let frame = Data([0xff, 0xfb, 0x90, 0xc0]) + Data(repeating: 0, count: 413)
            for _ in 0..<40 { data.append(frame) }
            try data.write(to: url)
            return
        }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let samples = try #require(buffer.floatChannelData?[0])
        samples.update(repeating: sample, count: Int(frameCount))
        let settings: [String: Any] = url.pathExtension == "m4a"
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000,
               AVNumberOfChannelsKey: 1]
            : [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
               AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
               AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let writer = try AVAudioFile(forWriting: url, settings: settings)
        try writer.write(from: buffer)
    }
}
