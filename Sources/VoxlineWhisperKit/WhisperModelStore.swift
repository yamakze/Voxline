import Foundation
import VoxlineCore
import WhisperKit

public enum WhisperModelDownloadProgress: Sendable {
    case files(component: String, fraction: Double)
    case checking
}

public struct WhisperModelInventory: Sendable {
    public enum State: Sendable { case missing, installed, loaded, incomplete(reason: String) }
    public let directory: URL
    public let byteCount: Int64
    public let state: State
}

/// Owns one local model installation and the loaded SDK instance used by future transcription.
public actor WhisperModelStore {
    public static let shared = WhisperModelStore()
    private let directory: URL?
    private var loadedKit: WhisperKit?
    private var loadedModelID: String?

    public init(directory: URL? = nil) { self.directory = directory }

    public func inventory(modelID: String) throws -> WhisperModelInventory {
        let manifest = try ModelFileManifest.baseline()
        guard modelID == manifest.modelID else { throw WhisperModelError.unknownModel }
        let root = try installationDirectory(modelID: modelID)
        if !FileManager.default.fileExists(atPath: root.path) {
            return WhisperModelInventory(directory: root, byteCount: 0, state: .missing)
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
            return WhisperModelInventory(directory: root, byteCount: bytes,
                                         state: loadedModelID == modelID ? .loaded : .installed)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return WhisperModelInventory(directory: root, byteCount: bytes, state: .incomplete(reason: error.localizedDescription))
        }
    }

    /// Re-download is an explicit fresh installation; partial files remain visible after cancellation.
    public func download(modelID: String,
                         onProgress: @escaping @Sendable (WhisperModelDownloadProgress) -> Void) async throws {
        let manifest = try ModelFileManifest.baseline()
        guard modelID == manifest.modelID else { throw WhisperModelError.unknownModel }
        guard loadedModelID != modelID else { throw WhisperModelError.loadedModel }
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
                onProgress(.files(component: "权重", fraction: progress.fractionCompleted))
            }
        // The pinned SDK may return partial files instead of throwing when cancelled.
        try Task.checkCancellation()
        let tokenizer = try await hub.snapshot(from: .init(id: manifest.tokenizerRepository),
            revision: manifest.tokenizerRevision, matching: manifest.tokenizerFiles.map(\.path)) { progress in
                onProgress(.files(component: "分词器", fraction: progress.fractionCompleted))
            }
        try Task.checkCancellation()
        onProgress(.checking)
        try ModelFileManifest.verify(manifest.modelFiles, in: modelRoot.appendingPathComponent(modelID), hashes: true)
        try ModelFileManifest.verify(manifest.tokenizerFiles, in: tokenizer, hashes: true)
        try Task.checkCancellation()
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("installation.json"), options: .atomic)
    }

    public func load(modelID: String) async throws {
        if loadedModelID == modelID { return }
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

    public func unload(modelID: String) {
        if loadedModelID == modelID { loadedKit = nil; loadedModelID = nil }
    }

    public func delete(modelID: String) throws {
        guard modelID == TranscriptionSettings.whisperKitBaseline.modelID else { throw WhisperModelError.unknownModel }
        guard loadedModelID != modelID else { throw WhisperModelError.loadedModel }
        try FileManager.default.removeItem(at: installationDirectory(modelID: modelID))
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
