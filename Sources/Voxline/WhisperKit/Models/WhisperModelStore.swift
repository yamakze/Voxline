import Foundation
import AVFoundation
import VoxlineCore
import WhisperKit

public enum WhisperModelDownloadProgress: Sendable {
    case files(component: String, fraction: Double)
    case checking
}

public struct WhisperModelInventory: Sendable {
    public enum State: Sendable { case missing, installed, loaded, incomplete(reason: String) }
    public let directory: URL
    public let revision: String
    public let byteCount: Int64
    public let state: State
}

/// Owns one local model installation and the single SDK worker used by transcription.
public actor WhisperModelStore {
    public static let shared = WhisperModelStore()
    private let directory: URL?
    private var loadedKit: WhisperKit?
    private var loadedModelID: String?
    private var operating = false {
        didSet { for observer in activityObservers.values { observer.yield(operating) } }
    }
    private var activityObservers: [UUID: AsyncStream<Bool>.Continuation] = [:]

    public init(directory: URL? = nil) { self.directory = directory }

    public func activityChanges() -> AsyncStream<Bool> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(2))
        activityObservers[id] = continuation
        continuation.yield(operating)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeActivityObserver(id) }
        }
        return stream
    }

    private func removeActivityObserver(_ id: UUID) { activityObservers[id] = nil }

    public func inventory(modelID: String) throws -> WhisperModelInventory {
        let manifest = try ModelFileManifest.baseline()
        guard modelID == manifest.modelID else { throw WhisperModelError.unknownModel }
        let root = try installationDirectory(modelID: modelID)
        if !FileManager.default.fileExists(atPath: root.path) {
            return WhisperModelInventory(directory: root, revision: manifest.modelRevision, byteCount: 0, state: .missing)
        }
        let bytes = try Self.diskUsage(in: root)
        do {
            let receipt = try JSONDecoder().decode(ModelFileManifest.self,
                from: Data(contentsOf: root.appendingPathComponent("installation.json")))
            guard receipt == manifest else { throw WhisperModelError.differentVersion }
            let hub = HubApiWrapper(downloadBase: root)
            let model = hub.localRepoLocation(.init(id: manifest.modelRepository)).appendingPathComponent(modelID)
            let tokenizer = hub.localRepoLocation(.init(id: manifest.tokenizerRepository))
            try ModelFileManifest.verify(manifest.modelFiles, in: model, hashes: false)
            try ModelFileManifest.verify(manifest.tokenizerFiles, in: tokenizer, hashes: false)
            return WhisperModelInventory(directory: root, revision: manifest.modelRevision, byteCount: bytes,
                                         state: loadedModelID == modelID ? .loaded : .installed)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return WhisperModelInventory(directory: root, revision: manifest.modelRevision, byteCount: bytes, state: .incomplete(reason: error.localizedDescription))
        }
    }

    /// Re-download is an explicit fresh installation; partial files remain visible after cancellation.
    public func download(modelID: String,
                         onProgress: @escaping @Sendable (WhisperModelDownloadProgress) -> Void) async throws {
        let manifest = try ModelFileManifest.baseline()
        guard modelID == manifest.modelID else { throw WhisperModelError.unknownModel }
        guard !operating else { throw WhisperTranscriptionError.busy }
        try unload(modelID: modelID)
        operating = true
        defer { operating = false }
        try Task.checkCancellation()
        let root = try installationDirectory(modelID: modelID)
        let parent = root.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: parent.path)
        guard let free = attributes[.systemFreeSize] as? NSNumber else { throw WhisperModelError.unavailableDiskSpace }
        let required = (manifest.modelFiles + manifest.tokenizerFiles).reduce(Int64(10_000_000)) { $0 + $1.byteCount }
        guard free.int64Value >= required else {
            throw WhisperModelError.insufficientSpace(required: required, available: free.int64Value)
        }
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let hub = HubApiWrapper(downloadBase: root)
        let modelRoot = try await hub.snapshot(from: .init(id: manifest.modelRepository),
            revision: manifest.modelRevision, matching: ["\(modelID)/*"]) { progress in
                onProgress(.files(component: String(localized: "权重", bundle: voxlineLocalizationBundle), fraction: progress.fractionCompleted))
            }
        // The pinned SDK may return partial files instead of throwing when cancelled.
        try Task.checkCancellation()
        let tokenizer = try await hub.snapshot(from: .init(id: manifest.tokenizerRepository),
            revision: manifest.tokenizerRevision, matching: manifest.tokenizerFiles.map(\.path)) { progress in
                onProgress(.files(component: String(localized: "分词器", bundle: voxlineLocalizationBundle), fraction: progress.fractionCompleted))
            }
        try Task.checkCancellation()
        onProgress(.checking)
        try ModelFileManifest.verify(manifest.modelFiles, in: modelRoot.appendingPathComponent(modelID), hashes: true)
        try ModelFileManifest.verify(manifest.tokenizerFiles, in: tokenizer, hashes: true)
        try Task.checkCancellation()
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("installation.json"), options: .atomic)
    }

    public func load(modelID: String) async throws {
        guard !operating else { throw WhisperTranscriptionError.busy }
        if loadedModelID == modelID { return }
        operating = true
        defer { operating = false }
        let manifest = try ModelFileManifest.baseline()
        guard modelID == manifest.modelID else { throw WhisperModelError.unknownModel }
        let inventory = try inventory(modelID: modelID)
        guard case .installed = inventory.state else {
            if case .incomplete(let reason) = inventory.state { throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: reason]) }
            throw WhisperModelError.notInstalled
        }
        let hub = HubApiWrapper(downloadBase: inventory.directory)
        let model = hub.localRepoLocation(.init(id: manifest.modelRepository)).appendingPathComponent(modelID)
        let tokenizer = hub.localRepoLocation(.init(id: manifest.tokenizerRepository))
        try ModelFileManifest.verify(manifest.modelFiles, in: model, hashes: true)
        try ModelFileManifest.verify(manifest.tokenizerFiles, in: tokenizer, hashes: true)
        let kit = try await Self.loadedModel(model: model, tokenizer: tokenizer, modelID: modelID)
        try Task.checkCancellation()
        loadedKit = kit
        loadedModelID = modelID
    }

    public func unload(modelID: String) throws {
        guard !operating else { throw WhisperTranscriptionError.busy }
        if loadedModelID == modelID { loadedKit = nil; loadedModelID = nil }
    }

    public func delete(modelID: String) throws {
        guard modelID == TranscriptionSettings.whisperKitBaseline.modelID else { throw WhisperModelError.unknownModel }
        guard !operating else { throw WhisperTranscriptionError.busy }
        try unload(modelID: modelID)
        try FileManager.default.removeItem(at: installationDirectory(modelID: modelID))
    }

    func transcribe(audio: TranscriptionAudio, settings: TranscriptionSettings, seeker: TranscriptionEvidenceSeeker,
                    onProgress: @escaping @Sendable (VoxlineCore.TranscriptionProgress) -> Void) async throws -> [RawTranscriptionSegment] {
        guard !operating else { throw WhisperTranscriptionError.busy }
        try Task.checkCancellation()
        onProgress(.readingAudio)
        let audioArray = try Self.readPCMSamples(audio)
        if loadedModelID != settings.modelID { onProgress(.loadingModel) }
        try await load(modelID: settings.modelID)
        try Task.checkCancellation()
        guard let kit = loadedKit, loadedModelID == settings.modelID else { throw WhisperModelError.notInstalled }
        operating = true
        let previousSeeker = kit.segmentSeeker
        kit.segmentSeeker = seeker
        defer { seeker.stopProgress(); kit.segmentSeeker = previousSeeker; operating = false }
        var language = settings.languageCode
        if settings.languageMode == .automatic {
            onProgress(.detectingLanguage)
            // The SDK transcription loop silently defaults after detection errors. This entry fails explicitly.
            let detected = try await kit.detectLangauge(audioArray: audioArray)
            guard Constants.languageCodes.contains(detected.language) else {
                throw WhisperTranscriptionError.unsupportedLanguage(detected.language)
            }
            language = detected.language
        }
        try Task.checkCancellation()
        let options = DecodingOptions(language: language,
            detectLanguage: false, skipSpecialTokens: true, wordTimestamps: true,
            windowClipTime: 0.02, concurrentWorkerCount: 1, chunkingStrategy: ChunkingStrategy.none)
        // Array entry bypasses the SDK incremental/VAD loader and its partial-success result merger.
        // SDK progress is dispatched in detached tasks: cancellation must belong to the caller's operation.
        let results = try await withTaskCancellationHandler {
            try await kit.transcribe(audioArray: audioArray, decodeOptions: options) { progress in
                if seeker.recordProgress(text: progress.text, tokens: progress.tokens) {
                    onProgress(.decoding(tokenCount: progress.tokens.count))
                }
                return seeker.isCancelled ? false : nil
            }
        } onCancel: { seeker.cancel() }
        seeker.stopProgress()
        try Task.checkCancellation()
        let segments = results.flatMap { $0.segments.map { TranscriptionEvidenceSeeker.raw($0, offset: seeker.sourceOffsetSeconds) } }
        return try TranscriptionEvidenceSeeker.validatedSegments(windows: seeker.windows,
            sourceOffsetSeconds: seeker.sourceOffsetSeconds, frameCount: audioArray.count, returnedSegments: segments)
    }

    /// AVAudioFile may return fewer frames than requested. Read until the declared PCM length is consumed.
    static func readPCMSamples(_ audio: TranscriptionAudio) throws -> [Float] {
        let file = try AVAudioFile(forReading: audio.localURL)
        let format = file.processingFormat
        guard format.sampleRate == 16_000, format.channelCount == 1,
              file.fileFormat.commonFormat == .pcmFormatFloat32, file.length > 0, file.length <= 1_920_000,
              audio.durationMilliseconds == (file.length + 15) / 16 else {
            throw WhisperTranscriptionError.invalidAudio
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000) else {
            throw WhisperTranscriptionError.invalidAudio
        }
        var samples = [Float]()
        samples.reserveCapacity(Int(file.length))
        while samples.count < Int(file.length) {
            try Task.checkCancellation()
            let requested = min(16_000, Int(file.length) - samples.count)
            try file.read(into: buffer, frameCount: AVAudioFrameCount(requested))
            guard buffer.frameLength > 0, Int(buffer.frameLength) <= requested, let data = buffer.floatChannelData?[0] else {
                throw WhisperTranscriptionError.invalidAudio
            }
            samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }
        return samples
    }

    private func installationDirectory(modelID: String) throws -> URL {
        let base: URL
        if let directory { base = directory }
        else {
            base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
                .appendingPathComponent("Voxline/Models", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(modelID, isDirectory: true)
    }

    private static func diskUsage(in directory: URL) throws -> Int64 {
        var bytes: Int64 = 0
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            if values.isDirectory == true { bytes += try diskUsage(in: url) }
            else if values.isRegularFile == true, let size = values.fileSize { bytes += Int64(size) }
        }
        return bytes
    }

    private nonisolated static func loadedModel(model: URL, tokenizer: URL, modelID: String) async throws -> sending WhisperKit {
        let config = try WhisperKitConfiguration.localModel(at: model,
            settings: TranscriptionSettings(modelID: modelID))
        config.load = false
        config.tokenizerFolder = tokenizer
        // Parse the pinned local tokenizer before SDK loading; malformed JSON must fail here.
        _ = try await AutoTokenizerWrapper.from(modelFolder: tokenizer)
        let kit = try await WhisperKit(config)
        try Task.checkCancellation()
        try await kit.loadModels()
        guard kit.modelState == .loaded else { throw WhisperModelError.notInstalled }
        return kit
    }
}
