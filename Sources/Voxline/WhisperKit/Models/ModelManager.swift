import Foundation
import Observation
import VoxlineCore

public enum ModelStatus: Equatable, Sendable {
    case notDownloaded
    case downloading(component: String, progress: Double)
    case checking, loading, cancelling, cancelled
    case downloaded(path: String, byteCount: Int64)
    case ready(path: String, byteCount: Int64)
    case failed(reason: String)
    case corrupted(reason: String)

    public var label: String {
        switch self {
        case .notDownloaded: "未下载"
        case .downloading(let component, let progress): String(format: "%@文件下载 %.0f%%", component, progress * 100)
        case .checking: "校验版本与文件"
        case .loading: "加载中"
        case .cancelling: "取消中"
        case .cancelled: "已取消，可重新下载"
        case .downloaded(_, let bytes), .ready(_, let bytes): String(format: "已安装 %.1f MB", Double(bytes) / 1_000_000)
        case .failed(let reason): "操作失败：\(reason)"
        case .corrupted(let reason): "安装不完整：\(reason)"
        }
    }
}

public struct WhisperModelDescriptor: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let expectedSizeMB: Double
    public let isBaseline: Bool
}

@Observable @MainActor
public final class ModelManager {
    public static let shared = ModelManager()
    public static let availableModels = [WhisperModelDescriptor(
        id: TranscriptionSettings.whisperKitBaseline.modelID,
        name: "Whisper · 626 MB 基准",
        description: "Whisper large-v3 压缩模型，使用固定仓库版本。本地处理不上传音频。",
        expectedSizeMB: 629.5, isBaseline: true)]

    public private(set) var modelStatuses: [String: ModelStatus] = [:]
    public private(set) var diskUsage: [String: Int64] = [:]
    public private(set) var modelDirectories: [String: URL] = [:]
    public private(set) var modelRevisions: [String: String] = [:]
    public var storageError: String?
    private let store: WhisperModelStore
    private struct Operation { let id: UUID; let task: Task<Void, Never> }
    private var operations: [String: Operation] = [:]

    init(store: WhisperModelStore = .shared) {
        self.store = store
        Task { await refreshAll() }
    }

    public func status(for modelID: String) -> ModelStatus { modelStatuses[modelID] ?? .notDownloaded }

    public func refreshAll() async {
        for model in Self.availableModels where operations[model.id] == nil {
            await refresh(modelID: model.id)
        }
    }

    public func refresh(modelID: String, preserveStatus: Bool = false) async {
        let previousStatus = modelStatuses[modelID]
        do {
            let inventory = try await store.inventory(modelID: modelID)
            guard operations[modelID] == nil, modelStatuses[modelID] == previousStatus else { return }
            diskUsage[modelID] = inventory.byteCount
            modelDirectories[modelID] = inventory.directory
            modelRevisions[modelID] = inventory.revision
            storageError = nil
            if preserveStatus { return }
            switch inventory.state {
            case .missing: modelStatuses[modelID] = .notDownloaded
            case .installed: modelStatuses[modelID] = .downloaded(path: inventory.directory.path, byteCount: inventory.byteCount)
            case .loaded: modelStatuses[modelID] = .ready(path: inventory.directory.path, byteCount: inventory.byteCount)
            case .incomplete(let reason): modelStatuses[modelID] = .corrupted(reason: reason)
            }
        } catch {
            guard operations[modelID] == nil, modelStatuses[modelID] == previousStatus else { return }
            storageError = error.localizedDescription
            if !preserveStatus { modelStatuses[modelID] = .failed(reason: error.localizedDescription) }
        }
    }

    public func download(modelID: String) {
        guard operations[modelID] == nil else { return }
        let operationID = UUID()
        modelStatuses[modelID] = .downloading(component: "权重", progress: 0)
        let task = Task {
            do {
                try await store.download(modelID: modelID) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.operations[modelID]?.id == operationID else { return }
                        switch progress {
                        case .files(let component, let fraction):
                            guard case .downloading(let current, let previous) = self.modelStatuses[modelID] else { return }
                            if current == "分词器" && component == "权重" { return }
                            if current == component && fraction < previous { return }
                            self.modelStatuses[modelID] = .downloading(component: component, progress: fraction)
                        case .checking:
                            guard case .downloading = self.modelStatuses[modelID] else { return }
                            self.modelStatuses[modelID] = .checking
                        }
                    }
                }
                try Task.checkCancellation()
                guard operations[modelID]?.id == operationID else { return }
                operations[modelID] = nil
                await refresh(modelID: modelID)
            } catch {
                guard operations[modelID]?.id == operationID else { return }
                modelStatuses[modelID] = Task.isCancelled ? .cancelled : .failed(reason: error.localizedDescription)
                operations[modelID] = nil
                await refresh(modelID: modelID, preserveStatus: true)
            }
        }
        operations[modelID] = Operation(id: operationID, task: task)
    }

    public func cancelDownload(modelID: String) {
        guard let operation = operations[modelID] else { return }
        operation.task.cancel()
        modelStatuses[modelID] = .cancelling
    }

    public func load(modelID: String) {
        guard operations[modelID] == nil else { return }
        let operationID = UUID()
        modelStatuses[modelID] = .loading
        let task = Task {
            do {
                try await store.load(modelID: modelID)
                guard operations[modelID]?.id == operationID else { return }
                operations[modelID] = nil
                await refresh(modelID: modelID)
            } catch {
                guard operations[modelID]?.id == operationID else { return }
                operations[modelID] = nil
                modelStatuses[modelID] = .failed(reason: error.localizedDescription)
                await refresh(modelID: modelID, preserveStatus: true)
            }
        }
        operations[modelID] = Operation(id: operationID, task: task)
    }

    public func unload(modelID: String) async {
        guard operations[modelID] == nil else { return }
        do {
            try await store.unload(modelID: modelID)
            await refresh(modelID: modelID)
        } catch { modelStatuses[modelID] = .failed(reason: error.localizedDescription) }
    }

    public func delete(modelID: String) async {
        guard operations[modelID] == nil else { return }
        do {
            try await store.unload(modelID: modelID)
            try await store.delete(modelID: modelID)
            await refresh(modelID: modelID)
        } catch {
            modelStatuses[modelID] = .failed(reason: error.localizedDescription)
        }
    }

    public func totalDiskUsage() -> Int64 { diskUsage.values.reduce(0, +) }
}
