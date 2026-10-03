import Foundation
import Observation
import VoxlineCore
import VoxlineMedia
import VoxlineTranslation

@Observable
@MainActor
final class TaskProcessingQueue {
    static let shared = TaskProcessingQueue(library: .shared)
    private let library: TaskLibrary
    private let pipeline: any MediaTranscriptionPipeline
    private let translationPipeline: any SubtitleTranslationPipeline
    private var worker: Task<Void, Never>?
    private var mediaWork: Task<Void, any Error>?
    private var queuedIDs: [UUID] = []
    private var cancelledIDs: Set<UUID> = []
    private var stopRequested = false
    private var progressID: UUID?
    private(set) var taskID: UUID?
    private(set) var mediaID: UUID?
    private(set) var isCancelling = false
    private(set) var progressText: String?
    private(set) var extractionFraction: Double?
    private(set) var errorMessage: String?

    init(library: TaskLibrary, pipeline: any MediaTranscriptionPipeline = LocalMediaTranscriptionPipeline(),
         translationPipeline: any SubtitleTranslationPipeline = LocalSubtitleTranslationPipeline()) {
        self.library = library
        self.pipeline = pipeline
        self.translationPipeline = translationPipeline
    }

    func start(taskID: UUID, mediaID: UUID? = nil) throws {
        guard worker == nil else { throw QueueError.busy }
        guard let task = library.task(for: taskID) else { throw CheckpointError.taskUnavailable }
        if let reason = ProcessingAvailability.reason(for: task) { throw QueueError.unavailable(reason) }
        let candidates = task.items.filter { item in
            (mediaID == nil || item.id == mediaID) && item.status != .completed &&
            !(item.checkpoint == nil && !item.cues.isEmpty) && item.media != nil
        }
        guard !candidates.isEmpty else { throw QueueError.noWork }
        let ids = candidates.map(\.id)
        try library.commitCheckpoint(taskID: taskID) { current in
            for index in current.items.indices where ids.contains(current.items[index].id) {
                if case .running = current.items[index].status { throw CheckpointError.workRunning }
                current.items[index].status = .pending
            }
            if current.startedAt == nil { try current.freezeParameters() }
        }
        self.taskID = taskID
        queuedIDs = ids
        cancelledIDs = []
        stopRequested = false
        isCancelling = false
        errorMessage = nil
        worker = Task { await self.consume(taskID: taskID, parameters: task.parameters) }
    }

    /// Cancellation keeps the worker occupied until the actual extraction/inference has returned.
    func cancel(mediaID requestedID: UUID? = nil) throws {
        guard let taskID else { return }
        if let requestedID {
            guard queuedIDs.contains(requestedID) || requestedID == mediaID else { throw CheckpointError.unknownWork }
            if requestedID == mediaID {
                cancelledIDs.insert(requestedID)
                isCancelling = true
                mediaWork?.cancel()
            } else {
                try updateMedia(taskID: taskID, mediaID: requestedID) { $0.status = .cancelled }
                cancelledIDs.insert(requestedID)
            }
        } else {
            // Commit waiting items first; a save error must be visible before cancellation is reported.
            try library.commitCheckpoint(taskID: taskID) { task in
                for index in task.items.indices where queuedIDs.contains(task.items[index].id) &&
                    task.items[index].id != mediaID && task.items[index].status != .completed {
                    task.items[index].status = .cancelled
                }
            }
            stopRequested = true
            isCancelling = true
            mediaWork?.cancel()
        }
    }

    func waitUntilIdle() async { await worker?.value }

    func startRetranslation(taskID: UUID, mediaID: UUID, cueIDs: [UUID], replacingExistingTranslations: Bool) throws {
        guard worker == nil else { throw QueueError.busy }
        guard let task = library.task(for: taskID),
              let item = task.items.first(where: { $0.id == mediaID }),
              let settings = task.parameters.translation else {
            throw QueueError.unavailable("本次任务未配置翻译服务，请使用启用翻译的任务。")
        }
        guard let checkpoint = item.checkpoint, checkpoint.chunks.allSatisfy(\.isCompleted) else {
            throw QueueError.unavailable("请先完成本次任务的转写，再重译字幕。")
        }
        let recovery = try item.recoveryPlan(media: checkpoint.media, parameters: task.parameters, ranges: checkpoint.chunks.map(\.range))
        guard recovery.translationBatchIDs.isEmpty else {
            throw QueueError.unavailable("存在未完成的翻译批次，请先在队列中继续或重试。")
        }
        let selected = Set(cueIDs)
        guard !selected.isEmpty, selected.count == cueIDs.count,
              selected.isSubset(of: Set(item.cues.map(\.id))) else { throw QueueError.noWork }
        if !replacingExistingTranslations, item.cues.contains(where: { cue in
            if case .succeeded = cue.translation { return selected.contains(cue.id) }
            return false
        }) { throw CheckpointError.existingResults }
        let batches = try SubtitleTranslationBatchPlanner.batches(cues: item.cues, pendingIDs: cueIDs, targetLanguage: settings.targetLanguage, batchSize: settings.batchSize)
        let batchIDs = try updateMedia(taskID: taskID, mediaID: mediaID) { current in
            try batches.map { try current.prepareTranslationBatch(cueIDs: $0, replacingExistingTranslations: replacingExistingTranslations) }
        }
        self.taskID = taskID
        queuedIDs = [mediaID]
        cancelledIDs = []
        stopRequested = false
        isCancelling = false
        errorMessage = nil
        worker = Task { await self.consume(taskID: taskID, parameters: task.parameters, translationBatchIDs: batchIDs) }
    }

    private func consume(taskID: UUID, parameters: TaskParameters, translationBatchIDs: [UUID]? = nil) async {
        defer {
            progressID = nil
            progressText = nil
            extractionFraction = nil
            mediaWork = nil
            mediaID = nil
            self.taskID = nil
            worker = nil
            isCancelling = false
        }
        for id in queuedIDs {
            queuedIDs.removeAll { $0 == id }
            if stopRequested { break }
            if cancelledIDs.contains(id) { continue }
            mediaID = id
            isCancelling = false
            let operation = Task {
                if let translationBatchIDs {
                    guard let settings = parameters.translation else { throw QueueError.unavailable("本次任务未配置翻译服务。") }
                    try await self.translateBatches(taskID: taskID, mediaID: id, settings: settings, batchIDs: translationBatchIDs)
                } else {
                    try await self.transcribeMedia(taskID: taskID, mediaID: id, parameters: parameters)
                }
            }
            mediaWork = operation
            do { try await operation.value }
            catch {
                // Provider failures are persisted inside transcribeMedia. An escaped failure is a
                // checkpoint/storage error: stop scheduling, preserve edits, and expose recovery.
                let stoppedReason = "队列停止，未提交的工作需要恢复：\(error.localizedDescription)"
                errorMessage = stoppedReason
                if var interrupted = library.task(for: taskID) {
                    interrupted.interruptRunningItems()
                    library.register(interrupted, at: library.url(for: taskID))
                    do { try library.save(interrupted) }
                    catch {
                        errorMessage = stoppedReason + " 中断状态仅保留在内存，保存失败：\(error.localizedDescription)"
                    }
                }
                break
            }
            mediaWork = nil
            progressID = nil
        }
    }

    private func transcribeMedia(taskID: UUID, mediaID: UUID, parameters: TaskParameters) async throws {
        guard let item = library.task(for: taskID)?.items.first(where: { $0.id == mediaID }),
              let media = item.media else { throw CheckpointError.taskUnavailable }
        try updateMedia(taskID: taskID, mediaID: mediaID) { $0.status = .running(stage: .audioExtraction) }
        let extractionID = UUID()
        progressID = extractionID
        progressText = "正在检查与提取音频"
        extractionFraction = nil
        let audio: [TranscriptionAudio]
        do {
            audio = try await pipeline.extract(item: item) { progress in
                Task { @MainActor in
                    guard self.progressID == extractionID else { return }
                    switch progress {
                    case .extracting(let fraction):
                        self.extractionFraction = fraction
                        self.progressText = "正在提取音频"
                    case .cacheInvalidated(let reason): self.progressText = "音频缓存失效，重新提取：\(reason)"
                    }
                }
            }
            try Task.checkCancellation()
        } catch {
            try updateMedia(taskID: taskID, mediaID: mediaID) {
                $0.status = Task.isCancelled || error is CancellationError ? .cancelled : .failed(reason: error.localizedDescription)
            }
            return
        }
        progressID = nil
        extractionFraction = nil
        let ranges = audio.map { TranscriptionChunkRange(sourceStartMilliseconds: $0.sourceStartMilliseconds,
                                                         durationMilliseconds: $0.durationMilliseconds) }
        let chunkIDs: [UUID]
        do {
            chunkIDs = try updateMedia(taskID: taskID, mediaID: mediaID) { item in
                if item.checkpoint == nil { try item.initializeCheckpoint(parameters: parameters, ranges: ranges) }
                return try item.recoveryPlan(media: media, parameters: parameters, ranges: ranges).transcriptionChunkIDs
            }
        } catch let error as CheckpointError {
            try updateMedia(taskID: taskID, mediaID: mediaID) { $0.status = .failed(reason: error.localizedDescription) }
            return
        }
        for chunkID in chunkIDs {
            if Task.isCancelled {
                try updateMedia(taskID: taskID, mediaID: mediaID) { $0.status = .cancelled }
                return
            }
            guard let chunks = library.task(for: taskID)?.items.first(where: { $0.id == mediaID })?.checkpoint?.chunks,
                  let index = chunks.firstIndex(where: { $0.id == chunkID }) else { throw CheckpointError.unknownWork }
            let sourceID = try updateMedia(taskID: taskID, mediaID: mediaID) { try $0.beginTranscriptionChunk(chunkID) }
            let decodingID = UUID()
            progressID = decodingID
            progressText = "转写块 \(index + 1)／\(chunks.count)"
            let evidence: TranscriptionEvidence
            do {
                evidence = try await pipeline.transcribe(audio: audio[index], settings: parameters.transcription) { progress in
                    Task { @MainActor in
                        guard self.progressID == decodingID else { return }
                        let detail: String
                        switch progress {
                        case .readingAudio: detail = "读取音频"
                        case .loadingModel: detail = "加载模型"
                        case .detectingLanguage: detail = "识别语言"
                        case .decoding(let count): detail = "已解码 \(count) 个词元"
                        case .completed(let count): detail = "已转写 \(count) 段，等待保存"
                        }
                        self.progressText = "块 \(index + 1)／\(chunks.count)：\(detail)"
                    }
                }
            } catch {
                progressID = nil
                let failure = error as? TranscriptionFailure
                if Task.isCancelled || error is CancellationError || failure?.isCancelled == true {
                    var cancelledEvidence = failure?.evidence
                    cancelledEvidence?.outcome = .cancelled
                    try updateMedia(taskID: taskID, mediaID: mediaID) {
                        try $0.recordTranscriptionCancellation(chunkID, sourceID: sourceID, evidence: cancelledEvidence)
                    }
                    return
                }
                try updateMedia(taskID: taskID, mediaID: mediaID) {
                    try $0.recordTranscriptionFailure(chunkID, sourceID: sourceID, reason: error.localizedDescription, evidence: failure?.evidence)
                }
                continue
            }
            progressID = nil
            if Task.isCancelled {
                var cancelledEvidence = evidence
                cancelledEvidence.outcome = .cancelled
                cancelledEvidence.failureReason = "处理已取消，保留未提交的转写证据。"
                try updateMedia(taskID: taskID, mediaID: mediaID) {
                    try $0.recordTranscriptionCancellation(chunkID, sourceID: sourceID, evidence: cancelledEvidence)
                }
                return
            }
            let result: SubtitleSegmentationResult
            do { result = try SubtitleSegmenter.segment(evidence, sourceID: sourceID, mediaDurationMilliseconds: media.durationMilliseconds) }
            catch {
                try updateMedia(taskID: taskID, mediaID: mediaID) {
                    try $0.recordTranscriptionFailure(chunkID, sourceID: sourceID, reason: error.localizedDescription, evidence: evidence)
                }
                continue
            }
            // Saving is outside the Provider catch: I/O failure must stop the queue rather than be
            // mistaken for a failed inference and allow later work to overwrite unsaved results.
            do {
                try updateMedia(taskID: taskID, mediaID: mediaID) { try $0.commitTranscriptionChunk(chunkID, result: result) }
            } catch let error as ProjectValidationError {
                // A newly submitted range can conflict with manual timing. Keep the edit and the
                // raw inference, fail this range, and let the other media continue.
                try updateMedia(taskID: taskID, mediaID: mediaID) {
                    try $0.recordTranscriptionFailure(chunkID, sourceID: sourceID, reason: error.localizedDescription, evidence: evidence)
                }
            }
        }
        if parameters.translation == nil, chunkIDs.isEmpty {
            try updateMedia(taskID: taskID, mediaID: mediaID) { $0.status = .completed }
        }
        if let translation = parameters.translation {
            try await translateMedia(taskID: taskID, mediaID: mediaID, settings: translation)
        }
    }

    private func translateMedia(taskID: UUID, mediaID: UUID, settings: TranslationSettings) async throws {
        guard let item = library.task(for: taskID)?.items.first(where: { $0.id == mediaID }),
              let checkpoint = item.checkpoint else { throw CheckpointError.missingCheckpoint }
        guard checkpoint.chunks.allSatisfy(\.isCompleted) else { return }
        if Task.isCancelled {
            try updateMedia(taskID: taskID, mediaID: mediaID) { $0.status = .cancelled }
            return
        }
        let plan = try item.recoveryPlan(media: checkpoint.media, parameters: checkpoint.parameters, ranges: checkpoint.chunks.map(\.range))
        let newBatches: [[UUID]]
        do {
            let pendingIDs = plan.untranslatedCueIDs.filter { id in
                guard let cue = item.cues.first(where: { $0.id == id }) else { return false }
                if case .succeeded = cue.translation { return false }
                return true
            }
            newBatches = try SubtitleTranslationBatchPlanner.batches(cues: item.cues, pendingIDs: pendingIDs,
                targetLanguage: settings.targetLanguage, batchSize: settings.batchSize)
        } catch {
            try updateMedia(taskID: taskID, mediaID: mediaID) { $0.status = .failed(reason: error.localizedDescription) }
            return
        }
        let batchIDs = try updateMedia(taskID: taskID, mediaID: mediaID) { item in
            try plan.translationBatchIDs + newBatches.map { try item.prepareTranslationBatch(cueIDs: $0) }
        }
        if batchIDs.isEmpty {
            try updateMedia(taskID: taskID, mediaID: mediaID) {
                $0.status = $0.cues.allSatisfy(\.hasCurrentTranslation) ? .completed : .needsReview
            }
            return
        }
        try await translateBatches(taskID: taskID, mediaID: mediaID, settings: settings, batchIDs: batchIDs)
    }

    private func translateBatches(taskID: UUID, mediaID: UUID, settings: TranslationSettings, batchIDs: [UUID]) async throws {
        for (index, batchID) in batchIDs.enumerated() {
            if Task.isCancelled {
                try updateMedia(taskID: taskID, mediaID: mediaID) { $0.status = .cancelled }
                return
            }
            let request: SubtitleTranslationRequest
            do {
                request = try updateMedia(taskID: taskID, mediaID: mediaID) { item in
                    try item.beginTranslationBatch(batchID)
                    guard let batch = item.checkpoint?.translationBatches.first(where: { $0.id == batchID }) else {
                        throw CheckpointError.unknownWork
                    }
                    return try SubtitleTranslationRequest(inputs: batch.inputs, cues: item.cues)
                }
            } catch let error as CheckpointError {
                try updateMedia(taskID: taskID, mediaID: mediaID) { $0.status = .failed(reason: error.localizedDescription) }
                return
            }
            progressText = "翻译批次 \(index + 1)／\(batchIDs.count)，等待服务响应"
            let outputs: [TranslationBatchOutput]
            do {
                outputs = try await translationPipeline.translate(settings: settings, request: request)
                try Task.checkCancellation()
            } catch {
                if Task.isCancelled || error is CancellationError {
                    try updateMedia(taskID: taskID, mediaID: mediaID) { try $0.recordTranslationCancellation(batchID) }
                } else {
                    try updateMedia(taskID: taskID, mediaID: mediaID) { try $0.recordTranslationFailure(batchID, reason: error.localizedDescription) }
                }
                return
            }
            do {
                try updateMedia(taskID: taskID, mediaID: mediaID) { try $0.commitTranslationBatch(batchID, outputs: outputs) }
            } catch let error as CheckpointError {
                try updateMedia(taskID: taskID, mediaID: mediaID) { try $0.recordTranslationFailure(batchID, reason: error.localizedDescription) }
                return
            }
        }
    }

    @discardableResult
    private func updateMedia<Result>(taskID: UUID, mediaID: UUID, mutation: (inout TaskMediaItem) throws -> Result) throws -> Result {
        try library.commitCheckpoint(taskID: taskID) { task in
            guard let index = task.items.firstIndex(where: { $0.id == mediaID }) else { throw CheckpointError.unknownWork }
            return try mutation(&task.items[index])
        }
    }
}

enum QueueError: Error, LocalizedError, Equatable {
    case busy, noWork, unavailable(String)
    var errorDescription: String? {
        switch self {
        case .busy: "已有任务处理中，请等待处理或取消结束后再开始。"
        case .noWork: "没有可处理的媒体；已完成成果与已有校对字幕不会重跑。"
        case .unavailable(let reason): reason
        }
    }
}
