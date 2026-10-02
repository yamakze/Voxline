import Foundation
import Observation
import VoxlineWhisperKit
import VoxlineCore

public enum ModelStatus: Equatable, Sendable {
    case notDownloaded
    case downloading(progress: Double)
    case loading
    case downloaded(path: String, byteCount: Int64)
    case failed(reason: String)
    case corrupted(reason: String)

    public var label: String {
        switch self {
        case .notDownloaded: return "未下载"
        case .downloading(let progress): return String(format: "下载中 %.0f%%", progress * 100)
        case .loading: return "加载中"
        case .downloaded(_, let byteCount):
            let mb = Double(byteCount) / 1_048_576
            return String(format: "本地文件 %.1f MB（待加载验证）", mb)
        case .failed(let reason): return "下载失败：\(reason)"
        case .corrupted(let reason): return "损坏：\(reason)"
        }
    }
}

public struct WhisperModelDescriptor: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let expectedSizeMB: Double
    public let isBaseline: Bool

    public init(id: String, name: String, description: String, expectedSizeMB: Double, isBaseline: Bool = false) {
        self.id = id
        self.name = name
        self.description = description
        self.expectedSizeMB = expectedSizeMB
        self.isBaseline = isBaseline
    }
}

@Observable
@MainActor
public final class ModelManager {
    public static let shared = ModelManager()

    public static let availableModels: [WhisperModelDescriptor] = [
        WhisperModelDescriptor(
            id: "openai_whisper-large-v3-v20240930_626MB",
            name: "Whisper Large v3 (Baseline)",
            description: "默认推荐模型，高精度转写英语与多语言，已针对 Apple Silicon 优化。",
            expectedSizeMB: 626.0,
            isBaseline: true
        ),
        WhisperModelDescriptor(
            id: "openai_whisper-large-v3-turbo_turbo_954MB",
            name: "Whisper Large v3 Turbo",
            description: "极速大模型，速度与质量兼备，适合长视频转写。",
            expectedSizeMB: 954.0
        ),
        WhisperModelDescriptor(
            id: "openai_whisper-base",
            name: "Whisper Base",
            description: "轻量级模型，资源占用极小，适合简单语音或快速预览。",
            expectedSizeMB: 145.0
        ),
        WhisperModelDescriptor(
            id: "openai_whisper-small",
            name: "Whisper Small",
            description: "平衡型模型，适合中等音质的日常对话与播客。",
            expectedSizeMB: 483.0
        ),
        WhisperModelDescriptor(
            id: "openai_whisper-tiny",
            name: "Whisper Tiny",
            description: "最小尺寸模型，仅用于极低内存环境验证。",
            expectedSizeMB: 75.0
        )
    ]

    public var modelStatuses: [String: ModelStatus] = [:]
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    public let modelsDirectory: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        modelsDirectory = appSupport.appendingPathComponent("Voxline/Models", isDirectory: true)
        refreshAll()
    }

    public func status(for modelID: String) -> ModelStatus {
        modelStatuses[modelID] ?? .notDownloaded
    }

    public func refreshAll() {
        for model in Self.availableModels {
            refresh(modelID: model.id)
        }
    }

    public func refresh(modelID: String) {
        if case .downloading = modelStatuses[modelID] { return }

        let targetDir = modelsDirectory.appendingPathComponent(modelID)
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: targetDir.path) {
            modelStatuses[modelID] = .notDownloaded
            return
        }

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: targetDir.path)
            if contents.isEmpty {
                modelStatuses[modelID] = .notDownloaded
                return
            }

            var totalBytes: Int64 = 0
            if let enumerator = fileManager.enumerator(at: targetDir, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let fileURL as URL in enumerator {
                    let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    if values.isRegularFile == true, let size = values.fileSize { totalBytes += Int64(size) }
                }
            }

            // Structural presence is not a successful model load.
            let hasModelFiles = ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy { component in
                contents.contains(component + ".mlmodelc") || contents.contains(component + ".mlpackage")
            }
            if !hasModelFiles {
                modelStatuses[modelID] = .corrupted(reason: "模型目录缺少必要权重文件或不完整。")
            } else {
                modelStatuses[modelID] = .downloaded(path: targetDir.path, byteCount: totalBytes)
            }
        } catch {
            modelStatuses[modelID] = .corrupted(reason: error.localizedDescription)
        }
    }

    public func download(modelID: String) {
        guard downloadTasks[modelID] == nil else { return }
        modelStatuses[modelID] = .downloading(progress: 0)

        let targetDir = modelsDirectory.appendingPathComponent(modelID)

        downloadTasks[modelID] = Task {
            do {
                try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

                _ = try await WhisperModelDownloads.download(
                    modelID: modelID,
                    directory: modelsDirectory,
                    onProgress: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.modelStatuses[modelID] = .downloading(progress: progress)
                        }
                    }
                )

                await MainActor.run {
                    self.downloadTasks[modelID] = nil
                    self.modelStatuses[modelID] = .notDownloaded
                    self.refresh(modelID: modelID)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.downloadTasks[modelID] = nil
                    self.modelStatuses[modelID] = .notDownloaded
                    self.refresh(modelID: modelID)
                }
            } catch {
                await MainActor.run {
                    self.downloadTasks[modelID] = nil
                    self.modelStatuses[modelID] = .failed(reason: error.localizedDescription)
                }
            }
        }
    }

    public func cancelDownload(modelID: String) {
        downloadTasks[modelID]?.cancel()
        downloadTasks[modelID] = nil
        modelStatuses[modelID] = .notDownloaded
        refresh(modelID: modelID)
    }

    public func delete(modelID: String) {
        cancelDownload(modelID: modelID)
        let targetDir = modelsDirectory.appendingPathComponent(modelID)
        do {
            try FileManager.default.removeItem(at: targetDir)
            modelStatuses[modelID] = .notDownloaded
        } catch {
            modelStatuses[modelID] = .failed(reason: error.localizedDescription)
        }
    }

    public func totalDiskUsage() -> Int64 {
        var total: Int64 = 0
        for status in modelStatuses.values {
            if case .downloaded(_, let bytes) = status {
                total += bytes
            }
        }
        return total
    }
}
