import Foundation

public struct ProcessingTask: Codable, Equatable, Identifiable, Sendable {
    public static let currentFormatVersion = 4
    public let formatVersion: Int
    public let id: UUID
    public var title: String
    public var items: [TaskMediaItem]
    public private(set) var parameters: TaskParameters
    public private(set) var startedAt: Date?

    public init(id: UUID = UUID(), title: String = "未命名任务", items: [TaskMediaItem] = [],
                parameters: TaskParameters = .baseline) {
        formatVersion = Self.currentFormatVersion
        self.id = id
        self.title = title
        self.items = items
        self.parameters = parameters
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, id, title, items, parameters, startedAt }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .formatVersion)
        guard version == 2 || version == 3 || version == Self.currentFormatVersion else {
            throw ProjectValidationError.unsupportedVersion(version)
        }
        formatVersion = Self.currentFormatVersion
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        items = try values.decode([TaskMediaItem].self, forKey: .items)
        parameters = try values.decode(TaskParameters.self, forKey: .parameters)
        startedAt = try values.decodeIfPresent(Date.self, forKey: .startedAt)
        if version == 2, items.contains(where: { $0.checkpoint != nil }) {
            throw CheckpointError.invalidRecord
        }
    }

    public mutating func updateParameters(_ parameters: TaskParameters) throws {
        guard startedAt == nil else { throw TaskValidationError.parametersFrozen }
        try parameters.validate()
        self.parameters = parameters
    }

    /// Freezes configuration only. The queue sets running states when actual work begins.
    public mutating func freezeParameters(at date: Date = Date()) throws {
        guard startedAt == nil else { throw TaskValidationError.parametersFrozen }
        try validate()
        guard !items.isEmpty else { throw TaskValidationError.noMedia }
        var hasReadyMedia = false
        for item in items {
            if case .failed = item.status { continue }
            if item.status == .cancelled { continue }
            guard item.media != nil else { throw TaskValidationError.unassociatedMedia(item.id) }
            hasReadyMedia = true
        }
        guard hasReadyMedia else { throw TaskValidationError.noReadyMedia }
        if let translation = parameters.translation, translation.serviceID == nil {
            throw TaskValidationError.unconfiguredTranslationService
        }
        startedAt = date
    }

    /// Opening a document does not reconnect a former executor; preserve its committed results.
    public mutating func interruptRunningItems() {
        for index in items.indices {
            if case .running(let stage) = items[index].status {
                items[index].status = .interrupted(stage: stage)
            }
            items[index].interruptCheckpointWork()
        }
    }

    public var status: ProcessingTaskStatus {
        if items.contains(where: { if case .running = $0.status { true } else { false } }) { return .running }
        if items.contains(where: { if case .interrupted = $0.status { true } else { false } }) { return .interrupted }
        if items.contains(where: { $0.status == .needsReview }) { return .needsReview }
        if items.isEmpty { return .draft }
        if items.contains(where: { $0.status == .pending }) { return startedAt == nil ? .draft : .queued }
        if items.allSatisfy({ $0.status == .completed }) { return .completed }
        let failed = items.contains { if case .failed = $0.status { true } else { false } }
        if failed { return completedCount > 0 ? .partiallyFailed : .failed }
        return .cancelled
    }

    public var completedCount: Int { items.filter { $0.status == .completed }.count }
    public var failedCount: Int { items.filter { if case .failed = $0.status { true } else { false } }.count }

    public func validate() throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw ProjectValidationError.unsupportedVersion(formatVersion)
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaskValidationError.emptyTitle
        }
        try parameters.validate()
        if startedAt != nil, let translation = parameters.translation, translation.serviceID == nil {
            throw TaskValidationError.unconfiguredTranslationService
        }
        var identities = Set<UUID>()
        for item in items {
            guard identities.insert(item.id).inserted else { throw TaskValidationError.duplicateMedia(item.id) }
            try item.validate()
            if let checkpoint = item.checkpoint {
                guard startedAt != nil else { throw TaskValidationError.workBeforeStart(item.id) }
                guard checkpoint.parameters == parameters else { throw CheckpointError.incompatibleContext }
            }
            switch item.status {
            case .running, .interrupted, .completed:
                guard startedAt != nil else { throw TaskValidationError.workBeforeStart(item.id) }
                guard item.media != nil else { throw TaskValidationError.unassociatedMedia(item.id) }
            case .pending, .needsReview, .failed, .cancelled: break
            }
        }
    }
}

public struct TaskParameters: Codable, Equatable, Sendable {
    public var transcription: TranscriptionSettings
    public var translation: TranslationSettings?
    public var srtOutputs: [SRTOutputKind]

    public init(transcription: TranscriptionSettings, translation: TranslationSettings? = nil,
                srtOutputs: [SRTOutputKind] = [.source]) {
        self.transcription = transcription
        self.translation = translation
        self.srtOutputs = srtOutputs
    }

    public static let baseline = TaskParameters(transcription: .whisperKitBaseline)

    public func validate() throws {
        try transcription.validate()
        try translation?.validate()
        guard !srtOutputs.isEmpty, Set(srtOutputs).count == srtOutputs.count else {
            throw TaskValidationError.invalidOutputs
        }
        guard translation != nil || srtOutputs.allSatisfy({ $0 == .source }) else {
            throw TaskValidationError.translationRequired
        }
    }
}

public enum SRTOutputKind: String, Codable, Sendable, Hashable {
    case source, translation, bilingual
}

public struct TaskMediaItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public let kind: TaskMediaKind
    public private(set) var source: TaskMediaSource
    public private(set) var media: MediaIdentity?
    public var status: TaskMediaStatus
    public var cues: [SubtitleCue]
    public internal(set) var checkpoint: MediaProcessingCheckpoint?

    public init(id: UUID = UUID(), title: String, kind: TaskMediaKind, source: TaskMediaSource,
                media: MediaIdentity? = nil, status: TaskMediaStatus = .pending, cues: [SubtitleCue] = []) {
        self.id = id
        self.title = title
        self.kind = kind
        self.source = source
        self.media = media
        self.status = status
        self.cues = cues
    }

    public mutating func associateMedia(_ candidate: MediaIdentity) throws {
        try candidate.validate()
        if let media, !media.matchesContent(of: candidate) { throw ProjectValidationError.differentMedia }
        var updated = self
        if updated.media == nil {
            updated.media = candidate
            updated.source = .localFile(fileName: candidate.fileName)
        }
        try updated.validate()
        self = updated
    }

    public var completedProcessingStatus: TaskMediaStatus {
        cues.contains { $0.requiresTimingReview == true } ? .needsReview : .completed
    }

    public mutating func confirmTimingReview(cueID: UUID) throws {
        guard let index = cues.firstIndex(where: { $0.id == cueID }) else { throw CheckpointError.unknownWork }
        var updated = self
        updated.cues[index].requiresTimingReview = nil
        if updated.status == .needsReview,
           let checkpoint, checkpoint.chunks.allSatisfy(\.isCompleted),
           checkpoint.parameters.translation == nil || updated.cues.allSatisfy(\.hasCurrentTranslation) {
            updated.status = updated.completedProcessingStatus
        }
        try updated.validate()
        self = updated
    }

    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaskValidationError.emptyMediaTitle(id)
        }
        switch source {
        case .unassociated:
            guard media == nil else { throw TaskValidationError.invalidSource(id) }
        case .localFile(let fileName):
            guard !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !fileName.contains("/"), !fileName.contains("\\"),
                  media == nil || media?.fileName == fileName else {
                throw TaskValidationError.invalidSource(id)
            }
        }
        try media?.validate()
        try SubtitleCue.validateTimeline(cues, within: media)
        try checkpoint?.validate(media: media, cues: cues, status: status)
        if case .failed(let reason) = status, reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw TaskValidationError.emptyFailureReason(id)
        }
    }
}

public enum TaskMediaKind: String, Codable, Sendable { case video, audio }

public enum TaskMediaSource: Codable, Equatable, Sendable {
    case unassociated
    case localFile(fileName: String)
}

public enum ProcessingStage: String, Codable, Sendable { case audioExtraction, transcription, translation }

public enum TaskMediaStatus: Codable, Equatable, Sendable {
    case pending, needsReview
    case running(stage: ProcessingStage)
    case completed
    case failed(reason: String)
    case cancelled
    case interrupted(stage: ProcessingStage)
}

public enum ProcessingTaskStatus: Sendable {
    case draft, queued, needsReview, running, interrupted, completed, partiallyFailed, failed, cancelled
}

public enum TaskValidationError: Error, LocalizedError, Equatable {
    case emptyTitle, taskChanged, parametersFrozen, noMedia, noReadyMedia, invalidOutputs, translationRequired, unconfiguredTranslationService
    case duplicateMedia(UUID), emptyMediaTitle(UUID), invalidSource(UUID), unassociatedMedia(UUID)
    case workBeforeStart(UUID), emptyFailureReason(UUID)

    public var errorDescription: String? {
        switch self {
        case .emptyTitle: "任务名称不能为空。"
        case .taskChanged: "提交期间任务已改变，请重新打开任务准备。"
        case .parametersFrozen: "本次参数已固定；更换参数需新建任务或明确重跑。"
        case .noMedia: "请先添加本地媒体。"
        case .noReadyMedia: "任务没有可开始的媒体，请修复失败条目或添加可用媒体。"
        case .invalidOutputs: "请选择不重复的 SRT 输出类型。"
        case .translationRequired: "译文和双语输出需要开启翻译。"
        case .unconfiguredTranslationService: "请为本次翻译选择已配置的本地服务。"
        case .duplicateMedia: "任务包含重复的媒体条目 ID。"
        case .emptyMediaTitle: "媒体名称不能为空。"
        case .invalidSource: "媒体来源与文件信息不一致。"
        case .unassociatedMedia: "请先关联媒体并选择音轨。"
        case .workBeforeStart: "未开始任务不能包含运行或已完成状态。"
        case .emptyFailureReason: "处理失败必须保留实际原因。"
        }
    }
}
