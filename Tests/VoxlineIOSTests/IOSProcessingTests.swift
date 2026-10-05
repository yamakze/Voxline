#if os(iOS)
import AVFoundation
import Foundation
import Testing
import VoxlineCore
import VoxlineMedia
import VoxlineWhisperKit
import VoxlineWorkflow
@testable import VoxlineApp

@Suite("iOS native media and queue", .serialized, .timeLimit(.minutes(1))) @MainActor
struct IOSProcessingTests {
    @Test func selectedAudioIsBoundedAndIOSQueuePersistsActualModelFailuresAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("native.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<16_000 { samples[index] = 0.125 }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            for _ in 0..<121 { try file.write(from: buffer) }
        }
        let inspection = try await MediaInspector.shared.inspect(url)
        let identity = try inspection.identity(audioTrackID: #require(inspection.audioTracks.first).id)
        let caches = root.appendingPathComponent("caches")
        let support = root.appendingPathComponent("support")
        let extractor = AudioExtractor(directory: caches.appendingPathComponent("Voxline/Audio"))
        let bookmarks = LocalMediaStore(directory: support.appendingPathComponent("Voxline/MediaAssociations"))
        let modelStore = WhisperModelStore(directory: root.appendingPathComponent("missing-model"))
        let evidenceRoot = caches.appendingPathComponent("Voxline/Transcription")
        let pipeline = LocalMediaTranscriptionPipeline(mediaStore: bookmarks, extractor: extractor,
            modelStore: modelStore, evidenceDirectory: evidenceRoot)
        let parameters = TaskParameters(transcription: .init(modelID: TranscriptionSettings.whisperKitBaseline.modelID,
            languageMode: .specified, languageCode: "en"))
        let task = ProcessingTask(title: "Native iOS", items: [
            .init(title: "Missing access", kind: .audio, source: .localFile(fileName: identity.fileName), media: identity),
            .init(title: "Native extraction", kind: .audio, source: .localFile(fileName: identity.fileName), media: identity)
        ], parameters: parameters)
        try await bookmarks.save(projectID: task.items[1].id, identity: identity, url: url)
        let library = IOSTaskLibrary(directory: root.appendingPathComponent("tasks"), pipeline: pipeline,
            resourceCleanup: .init(applicationSupport: support, caches: caches))
        try library.save(task)
        try library.queue.start(taskID: task.id)
        for _ in 0..<3000 {
            if library.queue.taskID == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(library.queue.taskID == nil)
        #expect(library.queue.errorMessage == nil)
        let processed = try #require(library.task(task.id))
        #expect(processed.items[0].status == .failed(reason: "找不到本机媒体文件，请在详情中重新关联。"))
        let checkpoint = try #require(processed.items[1].checkpoint)
        #expect(checkpoint.chunks.map(\.range.durationMilliseconds) == [120_000, 1000])
        #expect(checkpoint.parameters == parameters)
        #expect(processed.items[1].cues.isEmpty) // A missing model must never publish fake subtitles.
        #expect(processed.items[1].extractionState == .completed)
        #expect(processed.items[1].transcriptionState == .failed)
        for chunk in checkpoint.chunks {
            guard case .failed(_, let evidence) = chunk.state else { Issue.record("Model failure must be saved per range"); continue }
            #expect(evidence?.settings == parameters.transcription)
            #expect(evidence?.durationMilliseconds == chunk.range.durationMilliseconds)
        }
        let files = try FileManager.default.contentsOfDirectory(at: evidenceRoot.appendingPathComponent(task.items[1].id.uuidString), includingPropertiesForKeys: nil)
        #expect(files.count == 2) // The explicit media ID owns independent evidence, including failed runs.
        let reopened = IOSTaskLibrary(directory: library.storage.tasksDirectory, pipeline: pipeline,
            resourceCleanup: .init(applicationSupport: support, caches: caches))
        #expect(reopened.task(task.id) == processed)
        #expect(reopened.queue.taskID == nil) // Opening preserves results and does not restart processing.
        let extracted = try await extractor.extract(mediaURL: url, mediaID: task.items[1].id, identity: identity)
        #expect(extracted.reusedCache)
        #expect(extracted.chunks.map(\.sourceStartMilliseconds) == [0, 120_000])
        #expect(try AVAudioFile(forReading: extracted.chunks[1].localURL).length == 16_000)
        let native = try AVAudioFile(forReading: extracted.chunks[0].localURL)
        try native.read(into: buffer)
        #expect(abs(samples[0] - 0.125) < 0.001)
        try reopened.storage.delete(taskID: task.id)
        #expect(!FileManager.default.fileExists(atPath: files[0].path))
        #expect(!FileManager.default.fileExists(atPath: extracted.chunks[0].localURL.path))
        #expect(try await bookmarks.resolve(projectID: task.items[1].id, identity: identity) == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(IOSTaskLibrary(directory: library.storage.tasksDirectory).tasks.isEmpty)
    }
}

@Suite("iOS private S001 pipeline", .serialized, .timeLimit(.minutes(5))) @MainActor
struct IOSRealSampleTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXLINE_QUEUE_MEDIA"] != nil &&
                  ProcessInfo.processInfo.environment["VOXLINE_QUEUE_AUDIO"] != nil &&
                  ProcessInfo.processInfo.environment["VOXLINE_MODEL_DIRECTORY"] != nil))
    func realS001VideoAndAudioPersistNativeTranscriptionAndRepairOnlyFailedMedia() async throws {
        let environment = ProcessInfo.processInfo.environment
        let video = URL(fileURLWithPath: try #require(environment["VOXLINE_QUEUE_MEDIA"]))
        let audio = URL(fileURLWithPath: try #require(environment["VOXLINE_QUEUE_AUDIO"]))
        let models = URL(fileURLWithPath: try #require(environment["VOXLINE_MODEL_DIRECTORY"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("S001-\(UUID())")
        let bookmarks = LocalMediaStore(directory: root.appendingPathComponent("bookmarks"))
        let videoInspection = try await MediaInspector.shared.inspect(video)
        let audioInspection = try await MediaInspector.shared.inspect(audio)
        let videoTrack = try #require(videoInspection.audioTracks.first { $0.isDecodable })
        let audioTrack = try #require(audioInspection.audioTracks.first { $0.isDecodable })
        let videoIdentity = try videoInspection.identity(audioTrackID: videoTrack.id)
        let audioIdentity = try audioInspection.identity(audioTrackID: audioTrack.id)
        let pipeline = LocalMediaTranscriptionPipeline(mediaStore: bookmarks,
            extractor: AudioExtractor(directory: root.appendingPathComponent("audio")),
            modelStore: WhisperModelStore(directory: models), evidenceDirectory: root.appendingPathComponent("evidence"))
        let library = IOSTaskLibrary(directory: root.appendingPathComponent("tasks"), pipeline: pipeline)
        let task = ProcessingTask(title: "iOS real S001", items: [
            .init(title: "Missing bookmark", kind: .video, source: .localFile(fileName: videoIdentity.fileName), media: videoIdentity),
            .init(title: "S001 video", kind: .video, source: .localFile(fileName: videoIdentity.fileName), media: videoIdentity),
            .init(title: "S001 audio", kind: .audio, source: .localFile(fileName: audioIdentity.fileName), media: audioIdentity)
        ], parameters: .init(transcription: .init(modelID: TranscriptionSettings.whisperKitBaseline.modelID,
            languageMode: .specified, languageCode: "en")))
        try await bookmarks.save(projectID: task.items[1].id, identity: videoIdentity, url: video)
        try await bookmarks.save(projectID: task.items[2].id, identity: audioIdentity, url: audio)
        try library.save(task)
        try library.queue.start(taskID: task.id)
        while library.queue.taskID != nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(library.queue.errorMessage == nil)
        let processed = try #require(library.task(task.id))
        #expect(processed.items[0].status == .failed(reason: "找不到本机媒体文件，请在详情中重新关联。"))
        for item in processed.items.dropFirst() {
            #expect(item.hasCompletedTranscription)
            #expect(item.cues.count == 6)
            #expect(item.cues.last?.startMilliseconds ?? 0 > 28_000)
            #expect(item.status == .completed)
        }
        #expect(processed.items[1].cues.map(\.sourceText) == processed.items[2].cues.map(\.sourceText))
        for (v, a) in zip(processed.items[1].cues, processed.items[2].cues) {
            #expect(abs(v.startMilliseconds - a.startMilliseconds) <= 300)
        }
        let before = processed.items[1]
        var corrected = before
        try corrected.editSubtitle(comparedTo: #require(before.cues.first), sourceText: "Saved iOS correction", translationText: "")
        try library.storage.updateItem(corrected, taskID: task.id, comparedTo: before)
        let reopened = IOSTaskLibrary(directory: library.storage.tasksDirectory, pipeline: pipeline)
        #expect(reopened.task(task.id)?.items[1] == corrected)
        #expect(reopened.queue.taskID == nil)
        try await bookmarks.save(projectID: task.items[0].id, identity: videoIdentity, url: video)
        try reopened.queue.start(taskID: task.id, mediaID: task.items[0].id)
        while reopened.queue.taskID != nil { try await Task.sleep(for: .milliseconds(50)) }
        let saved = try TaskDocumentCodec.decode(Data(contentsOf: reopened.storage.defaultURL(for: task.id)))
        #expect(saved.status == .completed)
        #expect(saved.items[1] == corrected)
        #expect(saved.items[2] == processed.items[2])
        print("iOS native S001: real video/audio ASR, missing access isolation, restart and repaired retry preserve edits; \(reopened.storage.defaultURL(for: task.id).path)")
    }
}
#endif
