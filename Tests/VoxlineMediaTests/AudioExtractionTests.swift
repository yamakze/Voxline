import AVFoundation
import Foundation
import Synchronization
import Testing
import VoxlineCore
import VoxlineMedia

@Suite("Bounded PCM extraction and source timeline")
struct AudioExtractionTests {
    @Test func boundedChunksKeepAbsoluteOffsetsAndReuseCompleteCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("long.wav")
        try AudioFixture.write(to: url, frameCount: 121 * 16_000, sample: 0.25)
        let identity = try await MediaInspector.shared.inspect(url).identity(audioTrackID: 1)
        let extractor = AudioExtractor(directory: directory.appendingPathComponent("cache"))
        let mediaID = UUID()
        let audio = try await extractor.extract(mediaURL: url, mediaID: mediaID, identity: identity)
        #expect(!audio.reusedCache)
        #expect(audio.chunks.count == 2)
        #expect(audio.chunks.map(\.sourceStartMilliseconds) == [0, 120_000])
        #expect(audio.chunks.map(\.durationMilliseconds) == [120_000, 1000])
        for (index, chunk) in audio.chunks.enumerated() {
            let file = try AVAudioFile(forReading: chunk.localURL)
            #expect(file.length == (index == 0 ? 1_920_000 : 16_000))
            #expect(file.fileFormat.commonFormat == .pcmFormatFloat32)
            #expect(file.processingFormat.sampleRate == 16_000)
            #expect(file.processingFormat.channelCount == 1)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 100))
            try file.read(into: buffer)
            #expect(abs(try #require(buffer.floatChannelData?[0][0]) - 0.25) < 0.001)
        }
        let cached = try await extractor.extract(mediaURL: url, mediaID: mediaID, identity: identity)
        #expect(cached.reusedCache)
        #expect(cached.chunks.map(\.localURL) == audio.chunks.map(\.localURL))
    }

    @Test func finalFractionalMillisecondKeepsItsPCMFrame() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tail.wav")
        try AudioFixture.write(to: url, frameCount: 1_920_001)
        let inspection = try await MediaInspector.shared.inspect(url)
        let identity = try inspection.identity(audioTrackID: try #require(inspection.audioTracks.first).id)
        let audio = try await AudioExtractor(directory: directory.appendingPathComponent("cache"))
            .extract(mediaURL: url, mediaID: UUID(), identity: identity)
        #expect(audio.chunks.count == 2)
        let tail = try #require(audio.chunks.last)
        #expect(tail.sourceStartMilliseconds == 120_000 && tail.durationMilliseconds == 1)
        #expect(try AVAudioFile(forReading: tail.localURL).length == 1)
    }

    @Test func selectedTrackStartsAtSourceOffsetAndGapsArePreserved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try await MovieFixture.make(in: directory, withAudio: true)
        let asset = AVURLAsset(url: original)
        let composition = AVMutableComposition()
        let videos = try await asset.loadTracks(withMediaType: .video)
        let video = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try video.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 16000)),
                                  of: try #require(videos.first), at: .zero)
        for (index, value) in [Float(0.125), Float(0.25)].enumerated() {
            let sourceURL = directory.appendingPathComponent("audio-\(index).wav")
            try AudioFixture.write(to: sourceURL, sample: value)
            let audioAsset = AVURLAsset(url: sourceURL)
            let tracks = try await audioAsset.loadTracks(withMediaType: .audio)
            let source = try #require(tracks.first)
            let target = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            for start in [2.25, 4.5] {
                try target.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 16000)),
                                           of: source, at: CMTime(seconds: start, preferredTimescale: 16000))
            }
        }
        let url = directory.appendingPathComponent("timeline.mov")
        let exporter = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await exporter.export(to: url, as: .mov)
        let inspection = try await MediaInspector.shared.inspect(url)
        let track = try #require(inspection.audioTracks.last)
        let identity = try inspection.identity(audioTrackID: track.id)
        let audio = try await AudioExtractor(directory: directory.appendingPathComponent("cache"))
            .extract(mediaURL: url, mediaID: UUID(), identity: identity)
        #expect(audio.chunks.map(\.sourceStartMilliseconds) == [2250])
        #expect(audio.chunks.map(\.durationMilliseconds) == [3250])
        let file = try AVAudioFile(forReading: try #require(audio.chunks.first).localURL)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 100))
        try file.read(into: buffer)
        #expect(abs(try #require(buffer.floatChannelData?[0][0]) - 0.25) < 0.001)
        file.framePosition = 18_000 // Inside the 1.25-second source gap.
        try file.read(into: buffer)
        #expect(abs(try #require(buffer.floatChannelData?[0][0])) < 0.001)
        file.framePosition = 37_000 // After the source resumes at 4.5 seconds.
        try file.read(into: buffer)
        #expect(abs(try #require(buffer.floatChannelData?[0][0]) - 0.25) < 0.001)
    }

    @Test(arguments: ["m4a", "mp3", "wav"])
    func nativeAudioFormatsProducePCM(ext: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("input.\(ext)")
        try AudioFixture.write(to: url)
        let inspection = try await MediaInspector.shared.inspect(url)
        let identity = try inspection.identity(audioTrackID: try #require(inspection.audioTracks.first).id)
        let audio = try await AudioExtractor(directory: directory.appendingPathComponent("cache"))
            .extract(mediaURL: url, mediaID: UUID(), identity: identity)
        #expect(!audio.chunks.isEmpty)
        #expect(audio.chunks.allSatisfy { $0.durationMilliseconds > 0 && $0.durationMilliseconds <= 120_000 })
        let file = try AVAudioFile(forReading: try #require(audio.chunks.first).localURL)
        #expect(file.processingFormat.sampleRate == 16_000 && file.processingFormat.channelCount == 1)
    }

    @Test func missingCacheAndChangedSourceAreExplicit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("input.wav")
        try AudioFixture.write(to: url)
        let inspection = try await MediaInspector.shared.inspect(url)
        let identity = try inspection.identity(audioTrackID: try #require(inspection.audioTracks.first).id)
        let extractor = AudioExtractor(directory: directory.appendingPathComponent("cache"))
        let id = UUID()
        let audio = try await extractor.extract(mediaURL: url, mediaID: id, identity: identity)
        try FileManager.default.removeItem(at: try #require(audio.chunks.first).localURL)
        let invalidations = Mutex<[String]>([])
        let regenerated = try await extractor.extract(mediaURL: url, mediaID: id, identity: identity) { event in
            if case .cacheInvalidated(let reason) = event { invalidations.withLock { $0.append(reason) } }
        }
        #expect(!regenerated.reusedCache && invalidations.withLock { !$0.isEmpty })
        try AudioFixture.write(to: url, frameCount: 32_000)
        await #expect(throws: MediaAccessError.fileChanged) {
            try await extractor.extract(mediaURL: url, mediaID: id, identity: identity)
        }
        let changed = try await MediaInspector.shared.inspect(url)
        let newIdentity = try changed.identity(audioTrackID: try #require(changed.audioTracks.first).id)
        let refreshed = try await extractor.extract(mediaURL: url, mediaID: id, identity: newIdentity) { event in
            if case .cacheInvalidated(let reason) = event { invalidations.withLock { $0.append(reason) } }
        }
        #expect(refreshed.chunks.first?.durationMilliseconds == 2000)
        #expect(invalidations.withLock { $0.count } == 2)
    }

    @Test func corruptWAVIsRebuiltButPermissionFailureKeepsCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("input.wav")
        try AudioFixture.write(to: url)
        let identity = try await MediaInspector.shared.inspect(url).identity(audioTrackID: 1)
        let extractor = AudioExtractor(directory: directory.appendingPathComponent("cache"))
        let id = UUID()
        let audio = try await extractor.extract(mediaURL: url, mediaID: id, identity: identity)
        let chunk = try #require(audio.chunks.first).localURL
        let originalBytes = try Data(contentsOf: chunk)
        try Data(repeating: 0x41, count: 100).write(to: chunk)
        let invalidations = Mutex<[String]>([])
        let regenerated = try await extractor.extract(mediaURL: url, mediaID: id, identity: identity) { event in
            if case .cacheInvalidated(let reason) = event { invalidations.withLock { $0.append(reason) } }
        }
        #expect(!regenerated.reusedCache && invalidations.withLock { $0.count } == 1)
        #expect(try AVAudioFile(forReading: chunk).length == 16_000)
        #expect(try Data(contentsOf: chunk) == originalBytes)

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: chunk.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: chunk.path) }
        await #expect(throws: (any Error).self) {
            try await extractor.extract(mediaURL: url, mediaID: id, identity: identity) { event in
                if case .cacheInvalidated(let reason) = event { invalidations.withLock { $0.append(reason) } }
            }
        }
        #expect(invalidations.withLock { $0.count } == 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: chunk.path)
        #expect(try Data(contentsOf: chunk) == originalBytes)
    }

    @Test func cancelledExtractionCannotCommitCacheAndStorageErrorsThrow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("input.wav")
        try AudioFixture.write(to: url)
        let inspection = try await MediaInspector.shared.inspect(url)
        let identity = try inspection.identity(audioTrackID: try #require(inspection.audioTracks.first).id)
        let cache = directory.appendingPathComponent("cache")
        let id = UUID()
        let extractor = AudioExtractor(directory: cache)
        let task = Task {
            try await extractor.extract(mediaURL: url, mediaID: id, identity: identity) { event in
                if case .extracting(let fraction) = event, fraction > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: cache.appendingPathComponent(id.uuidString + "/audio.json").path))
        let recovered = try await extractor.extract(mediaURL: url, mediaID: id, identity: identity)
        #expect(!recovered.reusedCache)
        let occupied = directory.appendingPathComponent("occupied")
        try Data("occupied".utf8).write(to: occupied)
        await #expect(throws: (any Error).self) {
            try await AudioExtractor(directory: occupied).extract(mediaURL: url, mediaID: UUID(), identity: identity)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXLINE_AUDIO_SAMPLE"] != nil))
    func realSampleExtraction() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["VOXLINE_AUDIO_SAMPLE"])
        let url = URL(fileURLWithPath: path)
        let inspection = try await MediaInspector.shared.inspect(url)
        let identity = try inspection.identity(audioTrackID: try #require(inspection.audioTracks.first).id)
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/audio-validation")
        let audio = try await AudioExtractor(directory: directory).extract(mediaURL: url,
            mediaID: UUID(uuidString: "FA8D85AC-1BB5-4725-BEDE-820C09985EA8")!, identity: identity)
        #expect(!audio.chunks.isEmpty)
        #expect(audio.chunks.allSatisfy { $0.durationMilliseconds > 0 && $0.durationMilliseconds <= 120_000 })
        print("Real PCM: chunks=\(audio.chunks.count), starts=\(audio.chunks.map(\.sourceStartMilliseconds)), durations=\(audio.chunks.map(\.durationMilliseconds)), reused=\(audio.reusedCache)")
    }
}
