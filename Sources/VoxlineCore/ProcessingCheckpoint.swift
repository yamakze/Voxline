import Foundation

public struct TranscriptionChunkRange: Codable, Equatable, Sendable {
    public let sourceStartMilliseconds: Int64
    public let durationMilliseconds: Int64

    public init(sourceStartMilliseconds: Int64, durationMilliseconds: Int64) {
        self.sourceStartMilliseconds = sourceStartMilliseconds
        self.durationMilliseconds = durationMilliseconds
    }

    func validate(within media: MediaIdentity) throws {
        let (end, overflow) = sourceStartMilliseconds.addingReportingOverflow(durationMilliseconds)
        guard !overflow, sourceStartMilliseconds >= 0, durationMilliseconds > 0,
              durationMilliseconds <= 120_000, end <= media.durationMilliseconds else { throw CheckpointError.invalidRange }
    }
}

public struct TranscriptionChunkCheckpoint: Codable, Equatable, Identifiable, Sendable {
    public enum State: Codable, Equatable, Sendable {
        case pending, running(sourceID: UUID), interrupted
        case completed(SubtitleSegmentationResult)
        case failed(reason: String, evidence: TranscriptionEvidence?)
        case cancelled(evidence: TranscriptionEvidence?)
    }
    public let id: UUID
    public let range: TranscriptionChunkRange
    public internal(set) var state: State
    public var isCompleted: Bool { if case .completed = state { true } else { false } }
}

public struct TranslationBatchInput: Codable, Equatable, Sendable {
    public let cueID: UUID
    public let sourceText: String
    public let sourceRevision: UInt64
    public let previousTranslation: CueTranslation

    public init(_ cue: SubtitleCue) {
        cueID = cue.id
        sourceText = cue.sourceText
        sourceRevision = cue.sourceRevision
        previousTranslation = cue.translation
    }

    func matches(_ cue: SubtitleCue) -> Bool {
        cueID == cue.id && sourceText == cue.sourceText && sourceRevision == cue.sourceRevision &&
        previousTranslation == cue.translation
    }
}

public struct TranslationBatchOutput: Codable, Equatable, Sendable {
    public let cueID: UUID
    public let text: String
    public init(cueID: UUID, text: String) { self.cueID = cueID; self.text = text }
}

public struct TranslationBatchCheckpoint: Codable, Equatable, Identifiable, Sendable {
    public enum State: Codable, Equatable, Sendable {
        case pending, running, interrupted, failed(reason: String), cancelled
        case completed([TranslationBatchOutput])
    }
    public let id: UUID
    public let inputs: [TranslationBatchInput]
    public internal(set) var state: State
    public var isCompleted: Bool { if case .completed = state { true } else { false } }
}

public struct MediaProcessingCheckpoint: Codable, Equatable, Sendable {
    public let media: MediaIdentity
    public let parameters: TaskParameters
    public internal(set) var chunks: [TranscriptionChunkCheckpoint]
    public internal(set) var translationBatches: [TranslationBatchCheckpoint]

    func validate(media currentMedia: MediaIdentity?, cues: [SubtitleCue], status: TaskMediaStatus) throws {
        guard let currentMedia, media.matchesContent(of: currentMedia) else { throw CheckpointError.incompatibleContext }
        try media.validate()
        try parameters.validate()
        guard !chunks.isEmpty else { throw CheckpointError.invalidRecord }
        var chunkIDs = Set<UUID>()
        var sourceIDs = Set<UUID>()
        var generatedIDs = Set<UUID>()
        var previousEnd: Int64 = 0
        var runningCount = 0
        for chunk in chunks {
            try chunk.range.validate(within: media)
            // PCM ranges are declared in whole milliseconds; adjacent fractional ranges may share one ms.
            guard chunkIDs.insert(chunk.id).inserted,
                  chunk.range.sourceStartMilliseconds >= previousEnd - 1 else { throw CheckpointError.invalidRecord }
            previousEnd = chunk.range.sourceStartMilliseconds + chunk.range.durationMilliseconds
            switch chunk.state {
            case .pending, .interrupted: break
            case .running(let sourceID):
                runningCount += 1
                guard sourceIDs.insert(sourceID).inserted, status == .running(stage: .transcription) else {
                    throw CheckpointError.invalidRecord
                }
            case .completed(let result):
                try validateEvidence(result.evidence, range: chunk.range)
                guard sourceIDs.insert(result.sourceID).inserted else { throw CheckpointError.invalidRecord }
                let canonical = try SubtitleSegmenter.segment(result.evidence, sourceID: result.sourceID,
                    mediaDurationMilliseconds: media.durationMilliseconds, policy: result.policy)
                guard canonical.entries == result.entries,
                      canonical.excludedEmptySegmentIndices == result.excludedEmptySegmentIndices else { throw CheckpointError.invalidRecord }
                for cue in result.cues {
                    guard generatedIDs.insert(cue.id).inserted else { throw CheckpointError.invalidRecord }
                }
            case .failed(let reason, let evidence):
                guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CheckpointError.invalidRecord }
                if let evidence { try validateEvidence(evidence, range: chunk.range) }
            case .cancelled(let evidence):
                if let evidence {
                    try validateEvidence(evidence, range: chunk.range)
                    guard evidence.outcome == .cancelled else { throw CheckpointError.invalidRecord }
                }
            }
        }
        guard generatedIDs == Set(cues.map(\.id)) else { throw CheckpointError.invalidRecord }
        var batchIDs = Set<UUID>()
        var activeIDs = Set<UUID>()
        for batch in translationBatches {
            guard parameters.translation != nil, chunks.allSatisfy(\.isCompleted), batchIDs.insert(batch.id).inserted,
                  !batch.inputs.isEmpty, Set(batch.inputs.map(\.cueID)).count == batch.inputs.count else { throw CheckpointError.invalidRecord }
            for input in batch.inputs {
                guard let current = cues.first(where: { $0.id == input.cueID }),
                      input.sourceRevision > 0, input.sourceRevision <= current.sourceRevision,
                      input.sourceRevision != current.sourceRevision || input.sourceText == current.sourceText,
                      !input.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CheckpointError.invalidRecord }
                try input.previousTranslation.validate(cueID: input.cueID, sourceRevision: input.sourceRevision)
            }
            switch batch.state {
            case .running:
                runningCount += 1
                guard status == .running(stage: .translation) else { throw CheckpointError.invalidRecord }
                fallthrough
            case .pending, .interrupted:
                for input in batch.inputs {
                    guard activeIDs.insert(input.cueID).inserted else { throw CheckpointError.invalidRecord }
                }
            case .failed(let reason):
                guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CheckpointError.invalidRecord }
            case .cancelled: break
            case .completed(let outputs): try validateOutputs(outputs, inputs: batch.inputs)
            }
        }
        guard runningCount <= 1 else { throw CheckpointError.invalidRecord }
        if status == .completed {
            guard chunks.allSatisfy(\.isCompleted),
                  !cues.contains(where: { $0.requiresTimingReview == true }),
                  parameters.translation == nil || cues.allSatisfy(\.hasCurrentTranslation) else { throw CheckpointError.incompleteWork }
        }
    }

    func validateEvidence(_ evidence: TranscriptionEvidence, range: TranscriptionChunkRange) throws {
        guard evidence.sourceStartMilliseconds == range.sourceStartMilliseconds,
              evidence.durationMilliseconds == range.durationMilliseconds,
              evidence.settings == parameters.transcription else { throw CheckpointError.incompatibleContext }
        if evidence.outcome == .failed {
            guard let reason = evidence.failureReason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CheckpointError.invalidRecord
            }
        }
    }

    func validateOutputs(_ outputs: [TranslationBatchOutput], inputs: [TranslationBatchInput]) throws {
        guard outputs.count == inputs.count, Set(outputs.map(\.cueID)) == Set(inputs.map(\.cueID)),
              outputs.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw CheckpointError.invalidTranslationResult
        }
    }
}

public struct MediaRecoveryPlan: Equatable, Sendable {
    public let transcriptionChunkIDs: [UUID]
    public let translationBatchIDs: [UUID]
    public let outdatedTranslationBatchIDs: [UUID]
    public let untranslatedCueIDs: [UUID]
}

public extension TaskMediaItem {
    mutating func initializeCheckpoint(parameters: TaskParameters, ranges: [TranscriptionChunkRange]) throws {
        guard checkpoint == nil, cues.isEmpty else { throw CheckpointError.existingResults }
        guard let media else { throw TaskValidationError.unassociatedMedia(id) }
        var updated = self
        updated.checkpoint = MediaProcessingCheckpoint(media: media, parameters: parameters,
            chunks: ranges.map { .init(id: UUID(), range: $0, state: .pending) }, translationBatches: [])
        try updated.validate()
        self = updated
    }

    mutating func beginTranscriptionChunk(_ chunkID: UUID) throws -> UUID {
        var record = try checkpointForCurrentMedia()
        guard let index = record.chunks.firstIndex(where: { $0.id == chunkID }) else { throw CheckpointError.unknownWork }
        guard !record.chunks[index].isCompleted else { throw CheckpointError.alreadyCommitted }
        guard !record.chunks.contains(where: { if case .running = $0.state { true } else { false } }) else { throw CheckpointError.workRunning }
        let sourceID = UUID()
        record.chunks[index].state = .running(sourceID: sourceID)
        checkpoint = record
        status = .running(stage: .transcription)
        return sourceID
    }

    mutating func commitTranscriptionChunk(_ chunkID: UUID, result: SubtitleSegmentationResult) throws {
        var record = try checkpointForCurrentMedia()
        guard let index = record.chunks.firstIndex(where: { $0.id == chunkID }) else { throw CheckpointError.unknownWork }
        if case .completed(let committed) = record.chunks[index].state {
            guard committed == result else { throw CheckpointError.alreadyCommitted }
            return
        }
        guard case .running(let sourceID) = record.chunks[index].state, sourceID == result.sourceID else {
            throw CheckpointError.staleResult
        }
        try record.validateEvidence(result.evidence, range: record.chunks[index].range)
        var updated = self
        let followingIDs = Set(record.chunks.dropFirst(index + 1).flatMap { chunk -> [UUID] in
            if case .completed(let result) = chunk.state { return result.cues.map(\.id) }
            return []
        })
        let insertion = updated.cues.firstIndex { followingIDs.contains($0.id) } ?? updated.cues.endIndex
        updated.cues.insert(contentsOf: result.cues, at: insertion)
        record.chunks[index].state = .completed(result)
        updated.checkpoint = record
        if let reason = record.chunks.compactMap({ chunk -> String? in
            if case .failed(let reason, _) = chunk.state { return reason }
            return nil
        }).first { updated.status = .failed(reason: reason) }
        else if record.chunks.contains(where: { if case .cancelled = $0.state { true } else { false } }) { updated.status = .cancelled }
        else if record.chunks.contains(where: { $0.state == .interrupted }) { updated.status = .interrupted(stage: .transcription) }
        else { updated.status = record.chunks.allSatisfy(\.isCompleted) && record.parameters.translation == nil ? updated.completedProcessingStatus : .pending }
        try updated.validate()
        self = updated
    }

    mutating func recordTranscriptionFailure(_ chunkID: UUID, sourceID: UUID, reason: String,
                                            evidence: TranscriptionEvidence?) throws {
        var record = try checkpointForCurrentMedia()
        guard let index = record.chunks.firstIndex(where: { $0.id == chunkID }) else { throw CheckpointError.unknownWork }
        guard record.chunks[index].state == .running(sourceID: sourceID) else { throw CheckpointError.staleResult }
        var updated = self
        record.chunks[index].state = .failed(reason: reason, evidence: evidence)
        updated.checkpoint = record
        updated.status = .failed(reason: reason)
        try updated.validate()
        self = updated
    }

    mutating func recordTranscriptionCancellation(_ chunkID: UUID, sourceID: UUID,
                                                 evidence: TranscriptionEvidence? = nil) throws {
        var record = try checkpointForCurrentMedia()
        guard let index = record.chunks.firstIndex(where: { $0.id == chunkID }) else { throw CheckpointError.unknownWork }
        guard record.chunks[index].state == .running(sourceID: sourceID) else { throw CheckpointError.staleResult }
        var updated = self
        record.chunks[index].state = .cancelled(evidence: evidence)
        updated.checkpoint = record
        updated.status = .cancelled
        try updated.validate()
        self = updated
    }

    mutating func prepareTranslationBatch(cueIDs: [UUID], replacingExistingTranslations: Bool = false) throws -> UUID {
        var record = try checkpointForCurrentMedia()
        guard record.parameters.translation != nil, record.chunks.allSatisfy(\.isCompleted) else { throw CheckpointError.incompleteWork }
        guard !cueIDs.isEmpty, Set(cueIDs).count == cueIDs.count else { throw CheckpointError.invalidTranslationResult }
        let inputs = try cueIDs.map { id -> TranslationBatchInput in
            guard let cue = cues.first(where: { $0.id == id }) else { throw CheckpointError.unknownWork }
            if case .succeeded = cue.translation, !replacingExistingTranslations { throw CheckpointError.existingResults }
            return TranslationBatchInput(cue)
        }
        // Failed/cancelled or edited batches remain as history; valid unfinished inputs are reused.
        let plan = try recoveryPlan(media: record.media, parameters: record.parameters, ranges: record.chunks.map(\.range))
        let reusableIDs = Set(plan.translationBatchIDs)
        guard !record.translationBatches.filter({ reusableIDs.contains($0.id) }).contains(where: { batch in
            batch.inputs.contains { cueIDs.contains($0.cueID) }
        }) else { throw CheckpointError.workRunning }
        for index in record.translationBatches.indices where plan.outdatedTranslationBatchIDs.contains(record.translationBatches[index].id) {
            record.translationBatches[index].state = .failed(reason: "原文或译文已修改，请使用当前内容建立新批次。")
        }
        let batchID = UUID()
        record.translationBatches.append(.init(id: batchID, inputs: inputs, state: .pending))
        checkpoint = record
        if !record.translationBatches.contains(where: { $0.state == .running }) { status = .pending }
        return batchID
    }

    mutating func beginTranslationBatch(_ batchID: UUID) throws {
        var record = try checkpointForCurrentMedia()
        guard let index = record.translationBatches.firstIndex(where: { $0.id == batchID }) else { throw CheckpointError.unknownWork }
        guard !record.translationBatches[index].isCompleted else { throw CheckpointError.alreadyCommitted }
        guard !record.translationBatches.contains(where: { $0.state == .running }) else { throw CheckpointError.workRunning }
        guard record.translationBatches[index].inputs.allSatisfy({ input in cues.contains { input.matches($0) } }) else {
            throw CheckpointError.editedCue
        }
        record.translationBatches[index].state = .running
        checkpoint = record
        status = .running(stage: .translation)
    }

    mutating func commitTranslationBatch(_ batchID: UUID, outputs: [TranslationBatchOutput]) throws {
        var record = try checkpointForCurrentMedia()
        guard let index = record.translationBatches.firstIndex(where: { $0.id == batchID }) else { throw CheckpointError.unknownWork }
        let batch = record.translationBatches[index]
        if case .completed(let committed) = batch.state {
            guard committed == outputs else { throw CheckpointError.alreadyCommitted }
            return
        }
        guard batch.state == .running else { throw CheckpointError.staleResult }
        try record.validateOutputs(outputs, inputs: batch.inputs)
        guard batch.inputs.allSatisfy({ input in cues.contains { input.matches($0) } }) else { throw CheckpointError.editedCue }
        var updated = self
        for output in outputs {
            guard let cueIndex = updated.cues.firstIndex(where: { $0.id == output.cueID }) else { throw CheckpointError.unknownWork }
            updated.cues[cueIndex].translation = .succeeded(text: output.text, sourceRevision: updated.cues[cueIndex].sourceRevision)
        }
        record.translationBatches[index].state = .completed(outputs)
        updated.checkpoint = record
        let unfinished = record.translationBatches.filter { batch in
            !batch.isCompleted && batch.inputs.allSatisfy { input in updated.cues.contains { input.matches($0) } }
        }
        if updated.cues.allSatisfy(\.hasCurrentTranslation) { updated.status = updated.completedProcessingStatus }
        else if let reason = unfinished.compactMap({ batch -> String? in
            if case .failed(let reason) = batch.state { return reason }
            return nil
        }).first { updated.status = .failed(reason: reason) }
        else if unfinished.contains(where: { $0.state == .cancelled }) { updated.status = .cancelled }
        else if unfinished.contains(where: { $0.state == .interrupted }) { updated.status = .interrupted(stage: .translation) }
        else { updated.status = .pending }
        try updated.validate()
        self = updated
    }

    mutating func recordTranslationFailure(_ batchID: UUID, reason: String) throws {
        var record = try checkpointForCurrentMedia()
        guard let index = record.translationBatches.firstIndex(where: { $0.id == batchID }) else { throw CheckpointError.unknownWork }
        guard record.translationBatches[index].state == .running else { throw CheckpointError.staleResult }
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CheckpointError.invalidRecord }
        record.translationBatches[index].state = .failed(reason: reason)
        checkpoint = record
        status = .failed(reason: reason)
    }

    mutating func recordTranslationCancellation(_ batchID: UUID) throws {
        var record = try checkpointForCurrentMedia()
        guard let index = record.translationBatches.firstIndex(where: { $0.id == batchID }) else { throw CheckpointError.unknownWork }
        guard record.translationBatches[index].state == .running else { throw CheckpointError.staleResult }
        record.translationBatches[index].state = .cancelled
        checkpoint = record
        status = .cancelled
    }

    func recoveryPlan(media: MediaIdentity, parameters: TaskParameters, ranges: [TranscriptionChunkRange]) throws -> MediaRecoveryPlan {
        let record = try checkpointForCurrentMedia()
        guard record.media.matchesContent(of: media), record.parameters == parameters,
              record.chunks.map(\.range) == ranges else { throw CheckpointError.incompatibleContext }
        var reusable: [UUID] = []
        var outdated: [UUID] = []
        var reserved = Set<UUID>()
        for batch in record.translationBatches where !batch.isCompleted {
            if batch.inputs.allSatisfy({ input in cues.contains { input.matches($0) } }) {
                reusable.append(batch.id)
                reserved.formUnion(batch.inputs.map(\.cueID))
            } else { outdated.append(batch.id) }
        }
        let allTranscribed = record.chunks.allSatisfy(\.isCompleted)
        return MediaRecoveryPlan(transcriptionChunkIDs: record.chunks.filter { !$0.isCompleted }.map(\.id),
            translationBatchIDs: reusable, outdatedTranslationBatchIDs: outdated,
            untranslatedCueIDs: allTranscribed && parameters.translation != nil ?
                cues.filter { !$0.hasCurrentTranslation && !reserved.contains($0.id) }.map(\.id) : [])
    }

    internal mutating func interruptCheckpointWork() {
        guard var record = checkpoint else { return }
        for index in record.chunks.indices {
            if case .running = record.chunks[index].state { record.chunks[index].state = .interrupted }
        }
        for index in record.translationBatches.indices {
            if record.translationBatches[index].state == .running { record.translationBatches[index].state = .interrupted }
        }
        checkpoint = record
    }

    private func checkpointForCurrentMedia() throws -> MediaProcessingCheckpoint {
        guard let checkpoint else { throw CheckpointError.missingCheckpoint }
        guard let media, checkpoint.media.matchesContent(of: media) else { throw CheckpointError.incompatibleContext }
        return checkpoint
    }
}

public enum CheckpointError: Error, LocalizedError, Equatable {
    case missingCheckpoint, incompatibleContext, invalidRange, invalidRecord, unknownWork, taskUnavailable
    case existingResults, alreadyCommitted, workRunning, staleResult, editedCue, invalidTranslationResult, incompleteWork
    public var errorDescription: String? {
        switch self {
        case .missingCheckpoint: "媒体没有处理检查点。"
        case .incompatibleContext: "媒体、音轨或本次参数与检查点不一致，请明确重跑或新建任务。"
        case .invalidRange: "转写块范围无效或超出媒体。"
        case .invalidRecord: "处理检查点损坏或与字幕成果不一致。"
        case .unknownWork: "找不到对应的处理块、批次或字幕。"
        case .taskUnavailable: "任务已关闭、删除或无法读取，未提交处理结果。"
        case .existingResults: "已有字幕成果或当前译文，请明确选择重跑或重译。"
        case .alreadyCommitted: "该工作已提交，不能用不同结果替换已有成果。"
        case .workRunning: "已有处理或翻译批次占用这些输入。"
        case .staleResult: "结果不属于当前运行，未提交。"
        case .editedCue: "处理期间原文或译文已修改，保留校对内容，请重新建立翻译批次。"
        case .invalidTranslationResult: "翻译批次必须完整匹配字幕 ID，且每条译文非空。"
        case .incompleteWork: "处理尚未完整提交，不能开始翻译或标记完成。"
        }
    }
}
