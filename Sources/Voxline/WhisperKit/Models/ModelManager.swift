import Foundation
import Observation
import VoxlineCore

public enum ModelStatus: Equatable, Sendable {
    case notDownloaded
    case downloading(component: String, progress: Double)
    case checking, cancelling, cancelled
    case ready(path: String, byteCount: Int64)
    case failed(reason: String)
    case corrupted(reason: String)

    public var label: String {
        switch self {
        case .notDownloaded: String(localized: "未下载", bundle: voxlineLocalizationBundle)
        case .downloading(let component, let progress): String(format: String(localized: "%@文件下载 %.0f%%", bundle: voxlineLocalizationBundle), locale: .current, component, progress * 100)
        case .checking: String(localized: "检查文件", bundle: voxlineLocalizationBundle)
        case .cancelling: String(localized: "取消中", bundle: voxlineLocalizationBundle)
        case .cancelled: String(localized: "已取消，可重新下载", bundle: voxlineLocalizationBundle)
        case .ready(_, let bytes): String(format: String(localized: "已安装 %.1f MB", bundle: voxlineLocalizationBundle), locale: .current, Double(bytes) / 1_000_000)
        case .failed(let reason): String(localized: "操作失败：\(reason)", bundle: voxlineLocalizationBundle)
        case .corrupted(let reason): String(localized: "安装不完整：\(reason)", bundle: voxlineLocalizationBundle)
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
    public static let availableModels = WhisperModels.all.map(\.descriptor)

    public private(set) var modelStatuses: [String: ModelStatus] = [:]
    public private(set) var diskUsage: [String: Int64] = [:]
    public private(set) var modelDirectories: [String: URL] = [:]
    public private(set) var isOperating = false
    public private(set) var deletingModels: Set<String> = []
    public private(set) var deletionErrors: [String: String] = [:]
    public var storageError: String?
    private let store: WhisperModelStore
    private struct Operation { let id: UUID; let task: Task<Void, Never> }
    private var operations: [String: Operation] = [:]
    private var activityTask: Task<Void, Never>?

    init(store: WhisperModelStore = .shared) {
        self.store = store
        activityTask = Task { [weak self, store] in
            for await busy in await store.activityChanges() {
                guard let self else { return }
                self.isOperating = busy
                if !busy { await self.refreshAll() }
            }
        }
    }

    isolated deinit { activityTask?.cancel() }

    public func status(for modelID: String) -> ModelStatus { modelStatuses[modelID] ?? .notDownloaded }

    public func refreshAll() async {
        for model in Self.availableModels where operations[model.id] == nil {
            let preserveStatus: Bool
            switch modelStatuses[model.id] {
            case .cancelled, .failed: preserveStatus = true
            default: preserveStatus = false
            }
            await refresh(modelID: model.id, preserveStatus: preserveStatus)
        }
    }

    public func refresh(modelID: String, preserveStatus: Bool = false) async {
        let previousStatus = modelStatuses[modelID]
        do {
            let inventory = try await store.inventory(modelID: modelID)
            guard operations[modelID] == nil, modelStatuses[modelID] == previousStatus else { return }
            diskUsage[modelID] = inventory.byteCount
            modelDirectories[modelID] = inventory.directory
            storageError = nil
            if preserveStatus { return }
            switch inventory.state {
            case .missing: modelStatuses[modelID] = .notDownloaded
            case .installed, .loaded: modelStatuses[modelID] = .ready(path: inventory.directory.path, byteCount: inventory.byteCount)
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
        modelStatuses[modelID] = .downloading(component: String(localized: "权重", bundle: voxlineLocalizationBundle), progress: 0)
        let task = Task {
            do {
                try await store.download(modelID: modelID) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.operations[modelID]?.id == operationID else { return }
                        switch progress {
                        case .files(let component, let fraction):
                            guard case .downloading(let current, let previous) = self.modelStatuses[modelID] else { return }
                            if current == String(localized: "分词器", bundle: voxlineLocalizationBundle) && component == String(localized: "权重", bundle: voxlineLocalizationBundle) { return }
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

    public func delete(modelID: String) async {
        guard operations[modelID] == nil, !isOperating, !deletingModels.contains(modelID) else {
            deletionErrors[modelID] = String(localized: "当前处理尚未结束。", bundle: voxlineLocalizationBundle)
            return
        }
        deletingModels.insert(modelID)
        defer { deletingModels.remove(modelID) }
        deletionErrors[modelID] = nil
        do {
            try await store.delete(modelID: modelID)
        } catch {
            deletionErrors[modelID] = (error as? WhisperTranscriptionError) == .busy
                ? String(localized: "当前处理尚未结束。", bundle: voxlineLocalizationBundle) : error.localizedDescription
        }
        await refresh(modelID: modelID)
    }

    public func totalDiskUsage() -> Int64 { diskUsage.values.reduce(0, +) }
}
