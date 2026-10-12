import Foundation

public struct TranscriptionChunkRange: Codable, Hashable, Sendable {
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

/// Completed work is durable through its range, source and the item's editable cues.
public struct TranscriptionCompletion: Codable, Equatable, Sendable {
    public let sourceID: UUID
}

public struct TranscriptionChunkCheckpoint: Codable, Equatable, Identifiable, Sendable {
    public enum State: Codable, Equatable, Sendable {
        case pending, running(sourceID: UUID), interrupted
        case completed(TranscriptionCompletion)
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

    public func matches(_ cue: SubtitleCue) -> Bool {
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
        case completed
    }
    public let id: UUID
    public internal(set) var inputs: [TranslationBatchInput]
    public internal(set) var state: State
    public var isCompleted: Bool { if case .completed = state { true } else { false } }

    init(id: UUID, inputs: [TranslationBatchInput], state: State) {
        self.id = id
        self.inputs = inputs
        self.state = state
    }

    private enum CodingKeys: String, CodingKey { case id, inputs, state }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        state = try values.decode(State.self, forKey: .state)
        inputs = state == .completed ? [] : try values.decode([TranslationBatchInput].self, forKey: .inputs)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(state, forKey: .state)
        if !isCompleted { try values.encode(inputs, forKey: .inputs) }
    }
}

/// An execution-local index; current IDs and inputs are still checked before applying results.
public struct TranslationCheckpointIndex: Sendable {
    private let cuePositions: [UUID: Int]
    private let batchPositions: [UUID: Int]

    public init(item: TaskMediaItem) throws {
        guard let checkpoint = item.checkpoint else { throw CheckpointError.missingCheckpoint }
        var positions: [UUID: Int] = [:]
        positions.reserveCapacity(item.cues.count)
        for (position, cue) in item.cues.enumerated() {
            guard positions.updateValue(position, forKey: cue.id) == nil else { throw DomainValidationError.duplicateCue(cue.id) }
        }
        cuePositions = positions
        positions = [:]
        for (position, batch) in checkpoint.translationBatches.enumerated() {
            guard positions.updateValue(position, forKey: batch.id) == nil else { throw CheckpointError.invalidRecord }
        }
        batchPositions = positions
    }

    public func cuePosition(_ id: UUID, in cues: [SubtitleCue]) -> Int? {
        if let position = cuePositions[id], cues.indices.contains(position), cues[position].id == id { return position }
        // Structural edits can move or remove a cue while an external request is in flight.
        return cues.firstIndex { $0.id == id }
    }

    func batchPosition(_ id: UUID, in batches: [TranslationBatchCheckpoint]) -> Int? {
        if let position = batchPositions[id], batches.indices.contains(position), batches[position].id == id { return position }
        return batches.firstIndex { $0.id == id }
    }
}

public struct MediaProcessingCheckpoint: Codable, Equatable, Sendable {
    public let media: MediaIdentity
    public internal(set) var parameters: TaskParameters
    public internal(set) var chunks: [TranscriptionChunkCheckpoint]
    public internal(set) var translationBatches: [TranslationBatchCheckpoint]

    func validate(media currentMedia: MediaIdentity?, cues: [SubtitleCue], status: TaskMediaStatus, imported: Bool) throws {
        guard currentMedia != nil else { throw CheckpointError.incompatibleContext }
        try media.validate()
        try parameters.validate()
        guard imported ? chunks.isEmpty : !chunks.isEmpty else { throw CheckpointError.invalidRecord }
        var chunkIDs = Set<UUID>()
        var sourceIDs = Set<UUID>()
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
                guard sourceIDs.insert(result.sourceID).inserted else { throw CheckpointError.invalidRecord }
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
        // Recognition and translation snapshots describe past work, not the editable timeline.
        let allTranscribed = chunks.allSatisfy(\.isCompleted)
        var batchIDs = Set<UUID>()
        var activeIDs = Set<UUID>()
        for batch in translationBatches {
            guard parameters.translation != nil, allTranscribed, batchIDs.insert(batch.id).inserted,
                  batch.isCompleted || !batch.inputs.isEmpty,
                  Set(batch.inputs.map(\.cueID)).count == batch.inputs.count else { throw CheckpointError.invalidRecord }
            for input in batch.inputs {
                guard input.sourceRevision > 0,
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
            case .completed: break
            }
        }
        guard runningCount <= 1 else { throw CheckpointError.invalidRecord }
        if case .translationPaused = status {
            guard parameters.translation != nil, allTranscribed,
                  translationBatches.contains(where: { if case .failed = $0.state { true } else { false } }) else {
                throw CheckpointError.incompleteWork
            }
        }
        if status == .completed {
            guard allTranscribed,
                  parameters.translation == nil || cues.allSatisfy(\.hasTranslation) else { throw CheckpointError.incompleteWork }
        }
    }

    func validateEvidence(_ evidence: TranscriptionEvidence, range: TranscriptionChunkRange) throws {
        guard evidence.sourceStartMilliseconds == range.sourceStartMilliseconds,
              evidence.durationMilliseconds == range.durationMilliseconds else { throw CheckpointError.incompatibleContext }
        try evidence.settings.validate()
        // Historical evidence retains the configuration used for that recognition attempt.
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

    /// Replan unfinished audio without replacing committed recognition or the editable timeline.
    mutating func reconcileTranscriptionChunks(ranges: [TranscriptionChunkRange]) throws {
        var record = try requiredCheckpoint()
        var unfinished: [TranscriptionChunkRange: TranscriptionChunkCheckpoint] = [:]
        for chunk in record.chunks where !chunk.isCompleted {
            guard unfinished.updateValue(chunk, forKey: chunk.range) == nil else { throw CheckpointError.invalidRecord }
        }
        record.chunks = record.chunks.filter(\.isCompleted) + ranges.map { range in
            unfinished[range] ?? .init(id: UUID(), range: range, state: .pending)
        }
        record.chunks.sort { $0.range.sourceStartMilliseconds < $1.range.sourceStartMilliseconds }
        var updated = self
        updated.checkpoint = record
        try updated.validate()
        self = updated
    }

    mutating func beginTranscriptionChunk(_ chunkID: UUID, at position: Int? = nil) throws -> UUID {
        var record = try requiredCheckpoint()
        guard let media, record.media.matchesContent(of: media) else { throw CheckpointError.incompatibleContext }
        guard let index = position ?? record.chunks.firstIndex(where: { $0.id == chunkID }),
              record.chunks.indices.contains(index), record.chunks[index].id == chunkID else { throw CheckpointError.unknownWork }
        guard !record.chunks[index].isCompleted else { throw CheckpointError.alreadyCommitted }
        guard !record.chunks.contains(where: { if case .running = $0.state { true } else { false } }) else { throw CheckpointError.workRunning }
        let sourceID = UUID()
        record.chunks[index].state = .running(sourceID: sourceID)
        checkpoint = record
        status = .running(stage: .transcription)
        return sourceID
    }

    mutating func commitTranscriptionChunk(_ chunkID: UUID, result: SubtitleSegmentationResult, at position: Int? = nil) throws {
        var record = try requiredCheckpoint()
        guard let media, record.media.matchesContent(of: media) else { throw CheckpointError.incompatibleContext }
        guard let index = position ?? record.chunks.firstIndex(where: { $0.id == chunkID }),
              record.chunks.indices.contains(index), record.chunks[index].id == chunkID else { throw CheckpointError.unknownWork }
        if case .completed(let committed) = record.chunks[index].state {
            guard committed.sourceID == result.sourceID else { throw CheckpointError.alreadyCommitted }
            return
        }
        guard case .running(let sourceID) = record.chunks[index].state, sourceID == result.sourceID else {
            throw CheckpointError.staleResult
        }
        try record.validateEvidence(result.evidence, range: record.chunks[index].range)
        guard result.evidence.settings == record.parameters.transcription else { throw CheckpointError.staleResult }
        guard result.evidence.outcome == .completed else { throw SubtitleSegmentationError.incompleteTranscription }
        let recognized = result.evidence.segments.map(\.text).joined().precomposedStringWithCanonicalMapping.filter { !$0.isWhitespace }
        let subtitled = result.cues.map(\.sourceText).joined().precomposedStringWithCanonicalMapping.filter { !$0.isWhitespace }
        guard recognized == subtitled else { throw CheckpointError.invalidRecord }
        var updated = self
        let previousStart = updated.cues.last?.startMilliseconds
        updated.cues.append(contentsOf: result.cues)
        // Sequential chunks append directly; only a recovered earlier range needs reordering.
        if let previousStart, let incomingStart = result.cues.first?.startMilliseconds, incomingStart < previousStart {
            updated.cues.sort { $0.startMilliseconds < $1.startMilliseconds }
        }
        record.chunks[index].state = .completed(.init(sourceID: result.sourceID))
        updated.checkpoint = record
        if let reason = record.chunks.compactMap({ chunk -> String? in
            if case .failed(let reason, _) = chunk.state { return reason }
            return nil
        }).first { updated.status = .failed(reason: reason) }
        else if record.chunks.contains(where: { if case .cancelled = $0.state { true } else { false } }) { updated.status = .cancelled }
        else if record.chunks.contains(where: { $0.state == .interrupted }) { updated.status = .interrupted(stage: .transcription) }
        else { updated.status = record.chunks.allSatisfy(\.isCompleted) && record.parameters.translation == nil ? .completed : .pending }
        try updated.validate()
        self = updated
    }

    mutating func recordTranscriptionFailure(_ chunkID: UUID, sourceID: UUID, reason: String,
                                            evidence: TranscriptionEvidence?, at position: Int? = nil) throws {
        var record = try requiredCheckpoint()
        guard let media, record.media.matchesContent(of: media) else { throw CheckpointError.incompatibleContext }
        guard let index = position ?? record.chunks.firstIndex(where: { $0.id == chunkID }),
              record.chunks.indices.contains(index), record.chunks[index].id == chunkID else { throw CheckpointError.unknownWork }
        guard record.chunks[index].state == .running(sourceID: sourceID) else { throw CheckpointError.staleResult }
        var updated = self
        record.chunks[index].state = .failed(reason: reason, evidence: evidence)
        updated.checkpoint = record
        updated.status = .failed(reason: reason)
        try updated.validate()
        self = updated
    }

    mutating func recordTranscriptionCancellation(_ chunkID: UUID, sourceID: UUID,
                                                 evidence: TranscriptionEvidence? = nil, at position: Int? = nil) throws {
        var record = try requiredCheckpoint()
        guard let media, record.media.matchesContent(of: media) else { throw CheckpointError.incompatibleContext }
        guard let index = position ?? record.chunks.firstIndex(where: { $0.id == chunkID }),
              record.chunks.indices.contains(index), record.chunks[index].id == chunkID else { throw CheckpointError.unknownWork }
        guard record.chunks[index].state == .running(sourceID: sourceID) else { throw CheckpointError.staleResult }
        var updated = self
        record.chunks[index].state = .cancelled(evidence: evidence)
        updated.checkpoint = record
        updated.status = .cancelled
        try updated.validate()
        self = updated
    }

    mutating func prepareTranslationBatch(cueIDs: [UUID]) throws -> UUID {
        try prepareTranslationBatches(cueIDBatches: [cueIDs])[0]
    }

    /// Prepare a complete plan with one cue index and one recovery scan.
    mutating func prepareTranslationBatches(cueIDBatches: [[UUID]]) throws -> [UUID] {
        var record = try requiredCheckpoint()
        guard record.parameters.translation != nil, record.chunks.allSatisfy(\.isCompleted) else { throw CheckpointError.incompleteWork }
        let positions = try cuePositions()
        let plan = try recoveryPlan(media: record.media, parameters: record.parameters, ranges: record.chunks.map(\.range))
        let reusable = Set(plan.translationBatchIDs)
        var reserved = Set(record.translationBatches.filter { reusable.contains($0.id) }.flatMap { $0.inputs.map(\.cueID) })
        var requested = Set<UUID>()
        var added: [TranslationBatchCheckpoint] = []
        for ids in cueIDBatches {
            guard !ids.isEmpty else { throw CheckpointError.invalidTranslationResult }
            let inputs = try ids.map { id -> TranslationBatchInput in
                guard requested.insert(id).inserted else { throw CheckpointError.invalidTranslationResult }
                guard reserved.insert(id).inserted else { throw CheckpointError.workRunning }
                guard let position = positions[id] else { throw CheckpointError.unknownWork }
                return TranslationBatchInput(cues[position])
            }
            added.append(.init(id: UUID(), inputs: inputs, state: .pending))
        }
        let outdated = Set(plan.outdatedTranslationBatchIDs)
        for index in record.translationBatches.indices where outdated.contains(record.translationBatches[index].id) {
            record.translationBatches[index].state = .failed(reason: String(localized: "原文或译文已修改，请使用当前内容建立新批次。", bundle: voxlineLocalizationBundle))
        }
        record.translationBatches.append(contentsOf: added)
        checkpoint = record
        if !added.isEmpty, !record.translationBatches.contains(where: { $0.state == .running }) { status = .pending }
        return added.map(\.id)
    }

    @discardableResult
    mutating func beginTranslationBatch(_ batchID: UUID, using workIndex: TranslationCheckpointIndex? = nil) throws -> TranslationBatchCheckpoint {
        var record = try requiredCheckpoint()
        let workIndex = try workIndex ?? TranslationCheckpointIndex(item: self)
        guard let index = workIndex.batchPosition(batchID, in: record.translationBatches) else { throw CheckpointError.unknownWork }
        guard !record.translationBatches[index].isCompleted else { throw CheckpointError.alreadyCommitted }
        guard !record.translationBatches.contains(where: { $0.state == .running }) else { throw CheckpointError.workRunning }
        guard record.translationBatches[index].inputs.allSatisfy({ input in
            workIndex.cuePosition(input.cueID, in: cues).map { input.matches(cues[$0]) } == true
        }) else { throw CheckpointError.editedCue }
        record.translationBatches[index].state = .running
        checkpoint = record
        status = .running(stage: .translation)
        return record.translationBatches[index]
    }

    mutating func commitTranslationBatch(_ batchID: UUID, outputs: [TranslationBatchOutput],
                                        using workIndex: TranslationCheckpointIndex? = nil) throws {
        var record = try requiredCheckpoint()
        let workIndex = try workIndex ?? TranslationCheckpointIndex(item: self)
        guard let index = workIndex.batchPosition(batchID, in: record.translationBatches) else { throw CheckpointError.unknownWork }
        let batch = record.translationBatches[index]
        // An already committed request cannot apply again or replace subsequent manual edits.
        if batch.isCompleted { return }
        guard batch.state == .running else { throw CheckpointError.staleResult }
        try record.validateOutputs(outputs, inputs: batch.inputs)
        guard batch.inputs.allSatisfy({ input in
            workIndex.cuePosition(input.cueID, in: cues).map { input.matches(cues[$0]) } == true
        }) else { throw CheckpointError.editedCue }
        var updated = self
        for output in outputs {
            guard let cueIndex = workIndex.cuePosition(output.cueID, in: cues) else { throw CheckpointError.unknownWork }
            updated.cues[cueIndex].translation = .succeeded(text: output.text, sourceRevision: updated.cues[cueIndex].sourceRevision)
        }
        record.translationBatches[index].state = .completed
        record.translationBatches[index].inputs = []
        updated.checkpoint = record
        if updated.cues.allSatisfy(\.hasTranslation) { updated.status = .completed }
        else {
            var failure: String?
            var cancelled = false
            var interrupted = false
            var pending = false
            for other in record.translationBatches where !other.isCompleted {
                switch other.state {
                case .pending, .running:
                    // Pending inputs are checked when they begin, not after every other commit.
                    pending = true
                case .failed, .cancelled, .interrupted:
                    guard other.inputs.allSatisfy({ input in
                        workIndex.cuePosition(input.cueID, in: updated.cues).map { input.matches(updated.cues[$0]) } == true
                    }) else { continue }
                    switch other.state {
                    case .failed(let reason): if failure == nil { failure = reason }
                    case .cancelled: cancelled = true
                    case .interrupted: interrupted = true
                    default: break
                    }
                case .completed: break
                }
            }
            if let failure { updated.status = .failed(reason: failure) }
            else if cancelled { updated.status = .cancelled }
            else if interrupted { updated.status = .interrupted(stage: .translation) }
            else { updated.status = pending ? .running(stage: .translation) : .needsTranslation }
        }
        // Only text and this batch changed; full document validation belongs to persistence.
        self = updated
    }

    mutating func recordTranslationFailure(_ batchID: UUID, reason: String, pauseForRetry: Bool = false) throws {
        var record = try requiredCheckpoint()
        guard let index = record.translationBatches.firstIndex(where: { $0.id == batchID }) else { throw CheckpointError.unknownWork }
        guard record.translationBatches[index].state == .running else { throw CheckpointError.staleResult }
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CheckpointError.invalidRecord }
        record.translationBatches[index].state = .failed(reason: reason)
        checkpoint = record
        status = pauseForRetry ? .translationPaused(reason: reason) : .failed(reason: reason)
    }

    mutating func recordTranslationCancellation(_ batchID: UUID) throws {
        var record = try requiredCheckpoint()
        guard let index = record.translationBatches.firstIndex(where: { $0.id == batchID }) else { throw CheckpointError.unknownWork }
        guard record.translationBatches[index].state == .running else { throw CheckpointError.staleResult }
        record.translationBatches[index].state = .cancelled
        checkpoint = record
        status = .cancelled
    }

    func recoveryPlan(media: MediaIdentity, parameters: TaskParameters, ranges: [TranscriptionChunkRange]) throws -> MediaRecoveryPlan {
        let record = try requiredCheckpoint()
        guard record.media.matchesContent(of: media), record.parameters == parameters,
              record.chunks.map(\.range) == ranges else { throw CheckpointError.incompatibleContext }
        let positions = try cuePositions()
        var reusable: [UUID] = []
        var outdated: [UUID] = []
        var reserved = Set<UUID>()
        for batch in record.translationBatches where !batch.isCompleted {
            if batch.inputs.allSatisfy({ input in positions[input.cueID].map { input.matches(cues[$0]) } == true }) {
                reusable.append(batch.id)
                reserved.formUnion(batch.inputs.map(\.cueID))
            } else { outdated.append(batch.id) }
        }
        let allTranscribed = record.chunks.allSatisfy(\.isCompleted)
        return MediaRecoveryPlan(transcriptionChunkIDs: record.chunks.filter { !$0.isCompleted }.map(\.id),
            translationBatchIDs: reusable, outdatedTranslationBatchIDs: outdated,
            untranslatedCueIDs: allTranscribed && parameters.translation != nil ?
                cues.filter { !$0.hasTranslation && !reserved.contains($0.id) }.map(\.id) : [])
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

    private func cuePositions() throws -> [UUID: Int] {
        var positions: [UUID: Int] = [:]
        positions.reserveCapacity(cues.count)
        for (index, cue) in cues.enumerated() {
            guard positions.updateValue(index, forKey: cue.id) == nil else { throw DomainValidationError.duplicateCue(cue.id) }
        }
        return positions
    }

    private func requiredCheckpoint() throws -> MediaProcessingCheckpoint {
        guard let checkpoint else { throw CheckpointError.missingCheckpoint }
        return checkpoint
    }
}

public enum CheckpointError: Error, LocalizedError, Equatable {
    case missingCheckpoint, incompatibleContext, invalidRange, invalidRecord, unknownWork, taskUnavailable
    case existingResults, alreadyCommitted, workRunning, staleResult, editedCue, invalidTranslationResult, incompleteWork
    public var errorDescription: String? {
        switch self {
        case .missingCheckpoint: String(localized: "没有可恢复的处理成果。", bundle: voxlineLocalizationBundle)
        case .incompatibleContext: String(localized: "处理输入已变更，无法继续上次识别。", bundle: voxlineLocalizationBundle)
        case .invalidRange: String(localized: "识别时间超出媒体范围。", bundle: voxlineLocalizationBundle)
        case .invalidRecord: String(localized: "处理检查点损坏或与字幕成果不一致。", bundle: voxlineLocalizationBundle)
        case .unknownWork: String(localized: "找不到对应的处理成果。", bundle: voxlineLocalizationBundle)
        case .taskUnavailable: String(localized: "任务已关闭、删除或无法读取，未提交处理结果。", bundle: voxlineLocalizationBundle)
        case .existingResults: String(localized: "已有字幕成果或当前译文，请明确选择重跑或重译。", bundle: voxlineLocalizationBundle)
        case .alreadyCommitted: String(localized: "该工作已提交，不能用不同结果替换已有成果。", bundle: voxlineLocalizationBundle)
        case .workRunning: String(localized: "当前处理尚未结束。", bundle: voxlineLocalizationBundle)
        case .staleResult: String(localized: "结果不属于当前运行，未提交。", bundle: voxlineLocalizationBundle)
        case .editedCue: String(localized: "字幕已修改，本次结果未覆盖编辑。", bundle: voxlineLocalizationBundle)
        case .invalidTranslationResult: String(localized: "翻译结果缺失或格式无效，本批次未保存。", bundle: voxlineLocalizationBundle)
        case .incompleteWork: String(localized: "处理尚未完整提交，不能开始翻译或标记完成。", bundle: voxlineLocalizationBundle)
        }
    }
}
