import Foundation

public struct ProcessingTask: Codable, Equatable, Identifiable, Sendable {
    public static let currentFormatVersion = 6
    public let formatVersion: Int
    public let id: UUID
    public var title: String
    public var items: [TaskMediaItem]
    public private(set) var parameters: TaskParameters
    public private(set) var startedAt: Date?

    public init(id: UUID = UUID(), title: String = String(localized: "未命名任务", bundle: voxlineLocalizationBundle), items: [TaskMediaItem] = [],
                parameters: TaskParameters = .baseline) {
        formatVersion = Self.currentFormatVersion
        self.id = id
        self.title = title
        self.items = items
        self.parameters = parameters
    }

    /// A recovery copy keeps media and immutable evidence IDs, but never claims a local worker.
    public func duplicated(title: String? = nil) throws -> ProcessingTask {
        var copy = ProcessingTask(title: title ?? self.title + String(localized: " 副本", bundle: voxlineLocalizationBundle), items: items, parameters: parameters)
        copy.startedAt = startedAt
        copy.interruptRunningItems()
        try copy.validate()
        return copy
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, id, title, items, parameters, startedAt }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .formatVersion)
        guard version == 2 || version == 3 || version == 4 || version == 5 || version == Self.currentFormatVersion else {
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

    public var canChangeTranscription: Bool {
        items.allSatisfy { $0.checkpoint == nil && $0.cues.isEmpty }
    }

    /// Explicit edits retain ASR evidence; target changes require approval to replace translations.
    public mutating func updateParameters(_ parameters: TaskParameters, discardingTranslations: Bool = false) throws {
        guard !items.contains(where: { if case .running = $0.status { true } else { false } }) else {
            throw CheckpointError.workRunning
        }
        guard parameters.transcription == self.parameters.transcription || canChangeTranscription else {
            throw TaskValidationError.parametersFrozen
        }
        try parameters.validate()
        let translationChanged = parameters.translation != self.parameters.translation
        let targetChanged = parameters.translation?.targetLanguage != self.parameters.translation?.targetLanguage
        let replacesTranslations = targetChanged && parameters.translation != nil &&
            items.contains { $0.cues.contains { if case .succeeded = $0.translation { true } else { false } } }
        guard !replacesTranslations || discardingTranslations else {
            throw TaskValidationError.translationReplacementRequired
        }
        var updated = self
        updated.parameters = parameters
        for index in updated.items.indices {
            if replacesTranslations {
                for cueIndex in updated.items[index].cues.indices {
                    updated.items[index].cues[cueIndex].translation = .pending
                }
            }
            guard var checkpoint = updated.items[index].checkpoint else { continue }
            checkpoint.parameters = parameters
            if translationChanged { checkpoint.translationBatches = [] }
            updated.items[index].checkpoint = checkpoint
            if translationChanged && checkpoint.chunks.allSatisfy(\.isCompleted) {
                let item = updated.items[index]
                updated.items[index].status = parameters.translation == nil || item.cues.allSatisfy(\.hasCurrentTranslation)
                    ? item.completedProcessingStatus : .needsReview
            }
        }
        try updated.validate()
        self = updated
    }

    /// An explicit cloud service change affects future requests; recognition and edited cues survive.
    public mutating func bindCloudTranscription(_ settings: TranscriptionSettings) throws {
        try settings.validate()
        guard !items.contains(where: { if case .running = $0.status { true } else { false } }) else {
            throw CheckpointError.workRunning
        }
        let previous = parameters.transcription
        guard previous.provider == .openAICompatible, settings.provider == .openAICompatible,
              let oldCloud = previous.cloud, let newCloud = settings.cloud,
              oldCloud.protocolKind.usesSpeechChunks == newCloud.protocolKind.usesSpeechChunks,
              previous.languageMode == settings.languageMode, previous.languageCode == settings.languageCode else {
            throw CheckpointError.incompatibleContext
        }
        var updated = self
        updated.parameters.transcription = settings
        for index in updated.items.indices where updated.items[index].checkpoint != nil {
            updated.items[index].checkpoint?.parameters.transcription = settings
        }
        try updated.validate()
        self = updated
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
        if let translation = parameters.translation, case .openAICompatible(let api) = translation.engine, api.serviceID == nil {
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
        if items.contains(where: { if case .translationPaused = $0.status { true } else { false } }) { return .translationPaused }
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
        if startedAt != nil, let translation = parameters.translation, case .openAICompatible(let api) = translation.engine, api.serviceID == nil {
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
            case .running, .interrupted, .completed, .translationPaused:
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

    /// Legacy cues without processing evidence are proofreading results, not fresh ASR work.
    public var canResumeProcessing: Bool {
        media != nil && status != .completed && !(checkpoint == nil && !cues.isEmpty)
    }

    public var hasCompletedTranscription: Bool {
        guard let checkpoint else { return false }
        return !checkpoint.chunks.isEmpty && checkpoint.chunks.allSatisfy(\.isCompleted)
    }

    public var completedProcessingStatus: TaskMediaStatus {
        cues.contains { $0.requiresTimingReview == true } ? .needsReview : .completed
    }

    public mutating func editSubtitle(comparedTo original: SubtitleCue, sourceText: String, translationText: String) throws {
        guard let index = cues.firstIndex(where: { $0.id == original.id }),
              cues[index].sourceText == original.sourceText,
              cues[index].sourceRevision == original.sourceRevision,
              cues[index].translation == original.translation else { throw CheckpointError.editedCue }
        var edited = cues[index]
        try edited.replaceSourceText(with: sourceText)
        let previousTranslation: String
        if case .succeeded(let text, _) = original.translation { previousTranslation = text }
        else { previousTranslation = "" }
        if translationText != previousTranslation {
            edited.translation = translationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .pending : .succeeded(text: translationText, sourceRevision: edited.sourceRevision)
        }
        try edited.validate()
        cues[index] = edited
        updateProofreadingStatus()
    }

    private mutating func updateProofreadingStatus() {
        guard status == .completed || status == .needsReview,
              let checkpoint, checkpoint.chunks.allSatisfy(\.isCompleted) else { return }
        status = checkpoint.parameters.translation == nil || cues.allSatisfy(\.hasCurrentTranslation)
            ? completedProcessingStatus : .needsReview
    }

    public mutating func confirmTimingReview(cueID: UUID) throws {
        guard let index = cues.firstIndex(where: { $0.id == cueID }) else { throw CheckpointError.unknownWork }
        var updated = self
        updated.cues[index].requiresTimingReview = nil
        updated.updateProofreadingStatus()
        try updated.validate()
        self = updated
    }

    public mutating func confirmAllTimingReviews() throws {
        var updated = self
        for index in updated.cues.indices {
            updated.cues[index].requiresTimingReview = nil
        }
        updated.updateProofreadingStatus()
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
        switch status {
        case .failed(let reason), .translationPaused(let reason):
            if reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw TaskValidationError.emptyFailureReason(id)
            }
        default: break
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
    case translationPaused(reason: String)
}

public enum ProcessingTaskStatus: Sendable {
    case draft, queued, needsReview, running, interrupted, translationPaused, completed, partiallyFailed, failed, cancelled
}

public enum TaskValidationError: Error, LocalizedError, Equatable {
    case emptyTitle, taskChanged, translationReplacementRequired, parametersFrozen, noMedia, noReadyMedia, invalidOutputs, translationRequired, unconfiguredTranslationService
    case duplicateMedia(UUID), emptyMediaTitle(UUID), invalidSource(UUID), unassociatedMedia(UUID)
    case workBeforeStart(UUID), emptyFailureReason(UUID)

    public var errorDescription: String? {
        switch self {
        case .emptyTitle: String(localized: "任务名称不能为空。", bundle: voxlineLocalizationBundle)
        case .taskChanged: String(localized: "提交期间任务已改变，请重新打开任务准备。", bundle: voxlineLocalizationBundle)
        case .parametersFrozen: String(localized: "已有转写记录或字幕；更换模型或原文语言需新建任务。", bundle: voxlineLocalizationBundle)
        case .translationReplacementRequired: String(localized: "目标语言已改变，需要确认清除现有译文；原文、时间与转写成果保持。", bundle: voxlineLocalizationBundle)
        case .noMedia: String(localized: "请先添加本地媒体。", bundle: voxlineLocalizationBundle)
        case .noReadyMedia: String(localized: "任务没有可开始的媒体，请修复失败条目或添加可用媒体。", bundle: voxlineLocalizationBundle)
        case .invalidOutputs: String(localized: "请选择不重复的 SRT 输出类型。", bundle: voxlineLocalizationBundle)
        case .translationRequired: String(localized: "译文和双语输出需要开启翻译。", bundle: voxlineLocalizationBundle)
        case .unconfiguredTranslationService: String(localized: "请为本次翻译选择已配置的本地服务。", bundle: voxlineLocalizationBundle)
        case .duplicateMedia: String(localized: "任务包含重复的媒体条目 ID。", bundle: voxlineLocalizationBundle)
        case .emptyMediaTitle: String(localized: "媒体名称不能为空。", bundle: voxlineLocalizationBundle)
        case .invalidSource: String(localized: "媒体来源与文件信息不一致。", bundle: voxlineLocalizationBundle)
        case .unassociatedMedia: String(localized: "请先关联媒体并选择音轨。", bundle: voxlineLocalizationBundle)
        case .workBeforeStart: String(localized: "未开始任务不能包含运行或已完成状态。", bundle: voxlineLocalizationBundle)
        case .emptyFailureReason: String(localized: "处理失败必须保留实际原因。", bundle: voxlineLocalizationBundle)
        }
    }
}
