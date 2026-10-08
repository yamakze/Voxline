import Foundation
import Observation
import VoxlineCore
import VoxlineMedia
import VoxlineTranslation
import VoxlineWhisperKit

@Observable
@MainActor
public final class TaskProcessingQueue {
    private let library: TaskLibrary
    private let pipeline: any MediaTranscriptionPipeline
    private let translationPipeline: any SubtitleTranslationPipeline
    private let retrySleep: @Sendable (Duration) async throws -> Void
    private let retryJitter: @Sendable () -> Double
    private var worker: Task<Void, Never>?
    private var mediaWork: Task<Void, any Error>?
    private var queuedIDs: [UUID] = []
    private var cancelledIDs: Set<UUID> = []
    private var stopRequested = false
    private var progressID: UUID?
    public private(set) var taskID: UUID?
    public private(set) var mediaID: UUID?
    public private(set) var isCancelling = false
    public private(set) var progressText: String?
    public private(set) var extractionFraction: Double?
    public private(set) var errorMessage: String?
    public private(set) var translationRetryWait: TranslationRetryWait?
    @ObservationIgnored public var onFinish: (@MainActor () -> Void)?

    public init(library: TaskLibrary, pipeline: any MediaTranscriptionPipeline = ConfiguredMediaTranscriptionPipeline(),
         translationPipeline: any SubtitleTranslationPipeline,
         retrySleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         retryJitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.library = library
        self.pipeline = pipeline
        self.translationPipeline = translationPipeline
        self.retrySleep = retrySleep
        self.retryJitter = retryJitter
    }

    public func start(taskID: UUID, mediaID: UUID? = nil) throws {
        guard worker == nil else { throw QueueError.busy }
        guard let task = library.task(for: taskID) else { throw CheckpointError.taskUnavailable }
        guard !task.items.isEmpty else { throw QueueError.unavailable(String(localized: "请先添加本地音视频。", bundle: voxlineLocalizationBundle)) }
        let candidates = task.items.filter { item in
            (mediaID == nil || item.id == mediaID) && item.canResumeProcessing
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
        library.protectedTaskID = taskID
        queuedIDs = ids
        cancelledIDs = []
        stopRequested = false
        isCancelling = false
        errorMessage = nil
        worker = Task { await self.consume(taskID: taskID, parameters: task.parameters) }
    }

    public func isScheduled(mediaID: UUID) -> Bool {
        (queuedIDs.contains(mediaID) || self.mediaID == mediaID) && !cancelledIDs.contains(mediaID)
    }

    /// Cancellation keeps the worker occupied until the actual extraction/inference has returned.
    public func cancel(mediaID requestedID: UUID? = nil) throws {
        guard let taskID else { return }
        if let requestedID {
            guard queuedIDs.contains(requestedID) || requestedID == mediaID else { throw CheckpointError.unknownWork }
            if requestedID == mediaID {
                cancelledIDs.insert(requestedID)
                isCancelling = true
                mediaWork?.cancel()
            } else {
                try updateMedia(taskID: taskID, mediaID: requestedID, publishingImmediately: true) { $0.status = .cancelled }
                cancelledIDs.insert(requestedID)
            }
        } else {
            // Stop actual work even when persisting cancellation fails (including OS expiration).
            stopRequested = true
            isCancelling = true
            mediaWork?.cancel()
            do {
                try library.commitCheckpoint(taskID: taskID, publishingImmediately: true) { task in
                    for index in task.items.indices where queuedIDs.contains(task.items[index].id) &&
                        task.items[index].id != mediaID && task.items[index].status != .completed {
                        task.items[index].status = .cancelled
                    }
                }
            } catch {
                errorMessage = String(localized: "取消状态保存失败：\(error.localizedDescription)", bundle: voxlineLocalizationBundle)
                throw error
            }
        }
    }

    func waitUntilIdle() async { await worker?.value }

    public func startRetranslation(taskID: UUID, mediaID: UUID, cueIDs: [UUID], replacingExistingTranslations: Bool) throws {
        guard worker == nil else { throw QueueError.busy }
        guard let task = library.task(for: taskID),
              let item = task.items.first(where: { $0.id == mediaID }),
              let settings = task.parameters.translation else {
            throw QueueError.unavailable(String(localized: "本次任务未配置翻译服务，请使用启用翻译的任务。", bundle: voxlineLocalizationBundle))
        }
        guard let checkpoint = item.checkpoint, checkpoint.chunks.allSatisfy(\.isCompleted) else {
            throw QueueError.unavailable(String(localized: "请先完成本次任务的转写，再重译字幕。", bundle: voxlineLocalizationBundle))
        }
        let recovery = try item.recoveryPlan(media: checkpoint.media, parameters: task.parameters, ranges: checkpoint.chunks.map(\.range))
        guard recovery.translationBatchIDs.isEmpty else {
            throw QueueError.unavailable(String(localized: "存在未完成的翻译批次，请先在队列中继续或重试。", bundle: voxlineLocalizationBundle))
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
        library.protectedTaskID = taskID
        queuedIDs = [mediaID]
        cancelledIDs = []
        stopRequested = false
        isCancelling = false
        errorMessage = nil
        worker = Task { await self.consume(taskID: taskID, parameters: task.parameters, translationBatchIDs: batchIDs) }
    }

    private func consume(taskID: UUID, parameters: TaskParameters, translationBatchIDs: [UUID]? = nil) async {
        defer {
            do { try library.publishSharedCheckpoints() }
            catch { errorMessage = library.errorMessage ?? error.localizedDescription }
            progressID = nil
            progressText = nil
            extractionFraction = nil
            mediaWork = nil
            mediaID = nil
            self.taskID = nil
            library.protectedTaskID = nil
            worker = nil
            isCancelling = false
            onFinish?()
        }
        for id in queuedIDs {
            queuedIDs.removeAll { $0 == id }
            if stopRequested { break }
            if cancelledIDs.contains(id) { continue }
            mediaID = id
            isCancelling = false
            let operation = Task {
                if let translationBatchIDs {
                    guard let settings = parameters.translation else { throw QueueError.unavailable(String(localized: "本次任务未配置翻译服务。", bundle: voxlineLocalizationBundle)) }
                    try await self.translateBatches(taskID: taskID, mediaID: id, settings: settings, batchIDs: translationBatchIDs)
                } else if let settings = parameters.translation,
                          self.library.task(for: taskID)?.items.first(where: { $0.id == id })?
                            .checkpoint?.chunks.allSatisfy(\.isCompleted) == true {
                    try await self.translateMedia(taskID: taskID, mediaID: id, settings: settings)
                } else {
                    try await self.transcribeMedia(taskID: taskID, mediaID: id, parameters: parameters)
                }
            }
            mediaWork = operation
            do { try await operation.value }
            catch {
                // Provider failures are persisted inside transcribeMedia. An escaped failure is a
                // checkpoint/storage error: stop scheduling, preserve edits, and expose recovery.
                let stoppedReason = String(localized: "队列停止，未提交的工作需要恢复：\(error.localizedDescription)", bundle: voxlineLocalizationBundle)
                errorMessage = stoppedReason
                if var interrupted = library.task(for: taskID) {
                    interrupted.interruptRunningItems()
                    library.register(interrupted, at: library.url(for: taskID))
                    do { try library.save(interrupted) }
                    catch {
                        errorMessage = stoppedReason + String(localized: " 中断状态仅保留在内存，保存失败：\(error.localizedDescription)", bundle: voxlineLocalizationBundle)
                    }
                }
                break
            }
            do { try library.publishSharedCheckpoints() }
            catch { errorMessage = library.errorMessage ?? error.localizedDescription; break }
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
        progressText = String(localized: "正在检查与提取音频", bundle: voxlineLocalizationBundle)
        extractionFraction = nil
        let audio: [TranscriptionAudio]
        do {
            let extracted = try await pipeline.extract(item: item) { progress in
                Task { @MainActor in
                    guard self.progressID == extractionID else { return }
                    switch progress {
                    case .extracting(let fraction):
                        self.extractionFraction = fraction
                        self.progressText = String(localized: "正在提取音频", bundle: voxlineLocalizationBundle)
                    case .cacheInvalidated(let reason): self.progressText = String(localized: "音频缓存失效，重新提取：\(reason)", bundle: voxlineLocalizationBundle)
                    }
                }
            }
            audio = try await pipeline.speechChunks(from: extracted, settings: parameters.transcription)
            try Task.checkCancellation()
        } catch {
            try updateMedia(taskID: taskID, mediaID: mediaID, publishingImmediately: true) {
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
            try updateMedia(taskID: taskID, mediaID: mediaID, publishingImmediately: true) { $0.status = .failed(reason: error.localizedDescription) }
            return
        }
        for chunkID in chunkIDs {
            if Task.isCancelled {
                try updateMedia(taskID: taskID, mediaID: mediaID, publishingImmediately: true) { $0.status = .cancelled }
                return
            }
            guard let chunks = library.task(for: taskID)?.items.first(where: { $0.id == mediaID })?.checkpoint?.chunks,
                  let index = chunks.firstIndex(where: { $0.id == chunkID }) else { throw CheckpointError.unknownWork }
            let savedRecognition: TranscriptionEvidence?
            switch chunks[index].state {
            case .failed(_, let evidence), .cancelled(let evidence):
                savedRecognition = evidence?.cloudResult != nil ||
                    (evidence?.outcome == .completed && evidence?.settings.provider == .whisperKit && evidence?.windows.isEmpty == false)
                    ? evidence : nil
            default: savedRecognition = nil
            }
            let sourceID = try updateMedia(taskID: taskID, mediaID: mediaID) { try $0.beginTranscriptionChunk(chunkID) }
            let decodingID = UUID()
            progressID = decodingID
            progressText = String(localized: "转写块 \(index + 1)／\(chunks.count)", bundle: voxlineLocalizationBundle)
            let evidence: TranscriptionEvidence
            do {
                if let savedRecognition {
                    evidence = try savedRecognition.cloudResult != nil
                        ? CloudTranscriptionAlignment.completedEvidence(from: savedRecognition)
                        : WhisperKitTranscriptionProvider.recoverCompletedEvidence(savedRecognition)
                } else {
                    evidence = try await pipeline.transcribe(mediaID: mediaID, audio: audio[index], settings: parameters.transcription) { progress in
                        Task { @MainActor in
                            guard self.progressID == decodingID else { return }
                            let detail: String
                            switch progress {
                            case .uploadingAudio(let sent, let total): detail = String(localized: "上传音频 \(sent)／\(total) 字节", bundle: voxlineLocalizationBundle)
                            case .awaitingTranscription: detail = String(localized: "等待转写服务", bundle: voxlineLocalizationBundle)
                            case .retryingAudio(let attempt, let delay): detail = String(localized: "转写重试 \(attempt)／3，等待 \(Int(delay.rounded(.up))) 秒", bundle: voxlineLocalizationBundle)
                            case .readingAudio: detail = String(localized: "读取音频", bundle: voxlineLocalizationBundle)
                            case .loadingModel: detail = String(localized: "加载模型", bundle: voxlineLocalizationBundle)
                            case .detectingLanguage: detail = String(localized: "识别语言", bundle: voxlineLocalizationBundle)
                            case .decoding(let count): detail = String(localized: "已解码 \(count) 个词元", bundle: voxlineLocalizationBundle)
                            case .completed(let count): detail = String(localized: "已转写 \(count) 段，等待保存", bundle: voxlineLocalizationBundle)
                            }
                            self.progressText = String(localized: "块 \(index + 1)／\(chunks.count)：\(detail)", bundle: voxlineLocalizationBundle)
                        }
                    }
                }
            } catch {
                progressID = nil
                let failure = error as? TranscriptionFailure
                if Task.isCancelled || error is CancellationError || failure?.isCancelled == true {
                    var cancelledEvidence = failure?.evidence
                    cancelledEvidence?.outcome = .cancelled
                    try updateMedia(taskID: taskID, mediaID: mediaID, publishingImmediately: true) {
                        try $0.recordTranscriptionCancellation(chunkID, sourceID: sourceID, evidence: cancelledEvidence)
                    }
                    return
                }
                try updateMedia(taskID: taskID, mediaID: mediaID, publishingImmediately: true) {
                    try $0.recordTranscriptionFailure(chunkID, sourceID: sourceID, reason: error.localizedDescription, evidence: failure?.evidence ?? savedRecognition)
                }
                if let failure, case .http(let status, _) = failure.cause as? CloudTranscriptionError,
                   [429, 503].contains(status) { return }
                continue
            }
            progressID = nil
            if Task.isCancelled {
                var cancelledEvidence = evidence
                cancelledEvidence.outcome = .cancelled
                cancelledEvidence.failureReason = String(localized: "处理已取消，保留未提交的转写证据。", bundle: voxlineLocalizationBundle)
                try updateMedia(taskID: taskID, mediaID: mediaID, publishingImmediately: true) {
                    try $0.recordTranscriptionCancellation(chunkID, sourceID: sourceID, evidence: cancelledEvidence)
                }
                return
            }
            let result: SubtitleSegmentationResult
            do { result = try SubtitleSegmenter.segment(evidence, sourceID: sourceID, mediaDurationMilliseconds: media.durationMilliseconds) }
            catch {
                try updateMedia(taskID: taskID, mediaID: mediaID, publishingImmediately: true) {
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
                try updateMedia(taskID: taskID, mediaID: mediaID, publishingImmediately: true) {
                    try $0.recordTranscriptionFailure(chunkID, sourceID: sourceID, reason: error.localizedDescription, evidence: evidence)
                }
            }
        }
        if parameters.translation == nil, chunkIDs.isEmpty {
            try updateMedia(taskID: taskID, mediaID: mediaID) { $0.status = $0.completedProcessingStatus }
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
            try updateMedia(taskID: taskID, mediaID: mediaID, publishingImmediately: true) { $0.status = .cancelled }
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
            try updateMedia(taskID: taskID, mediaID: mediaID, publishingImmediately: true) { $0.status = .failed(reason: error.localizedDescription) }
            return
        }
        let batchIDs = try updateMedia(taskID: taskID, mediaID: mediaID) { item in
            try plan.translationBatchIDs + newBatches.map { try item.prepareTranslationBatch(cueIDs: $0) }
        }
        if batchIDs.isEmpty {
            try updateMedia(taskID: taskID, mediaID: mediaID) {
                $0.status = $0.cues.allSatisfy(\.hasCurrentTranslation) ? $0.completedProcessingStatus : .needsReview
            }
            return
        }
        try await translateBatches(taskID: taskID, mediaID: mediaID, settings: settings, batchIDs: batchIDs)
    }

    private func translateBatches(taskID: UUID, mediaID: UUID, settings: TranslationSettings, batchIDs: [UUID]) async throws {
        defer { translationRetryWait = nil }
        for batchID in batchIDs {
            if Task.isCancelled {
                try updateMedia(taskID: taskID, mediaID: mediaID, publishingImmediately: true) { $0.status = .cancelled }
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
                try updateMedia(taskID: taskID, mediaID: mediaID, publishingImmediately: true) { $0.status = .failed(reason: error.localizedDescription) }
                return
            }
            guard let current = library.task(for: taskID)?.items.first(where: { $0.id == mediaID }),
                  let batches = current.checkpoint?.translationBatches,
                  let batchIndex = batches.firstIndex(where: { $0.id == batchID }) else { throw CheckpointError.unknownWork }
            progressText = String(localized: "已译 \(current.cues.filter(\.hasCurrentTranslation).count)／\(current.cues.count) 句，翻译批次 \(batchIndex + 1)／\(batches.count)", bundle: voxlineLocalizationBundle)
            var outputs: [TranslationBatchOutput]?
            var retries = 0
            while outputs == nil {
                do {
                    try Task.checkCancellation()
                    if retries > 0 {
                        guard let latest = library.task(for: taskID)?.items.first(where: { $0.id == mediaID }),
                              request.inputs.allSatisfy({ input in latest.cues.contains { input.matches($0) } }) else {
                            throw CheckpointError.editedCue
                        }
                    }
                    outputs = try await translationPipeline.translate(settings: settings, request: request)
                    try Task.checkCancellation()
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        try updateMedia(taskID: taskID, mediaID: mediaID, publishingImmediately: true) { try $0.recordTranslationCancellation(batchID) }
                        return
                    }
                    let delay = (error as? SubtitleTranslationError)?.retryDelay(attempt: retries + 1, jitter: retryJitter())
                    guard let delay, retries < 3 else {
                        try updateMedia(taskID: taskID, mediaID: mediaID, publishingImmediately: true) {
                            try $0.recordTranslationFailure(batchID, reason: error.localizedDescription, pauseForRetry: delay != nil)
                        }
                        return
                    }
                    retries += 1
                    translationRetryWait = TranslationRetryWait(deadline: .now.addingTimeInterval(delay),
                        attempt: retries, reason: error.localizedDescription)
                    do {
                        try await retrySleep(.seconds(delay))
                        try Task.checkCancellation()
                    } catch {
                        if Task.isCancelled || error is CancellationError {
                            try updateMedia(taskID: taskID, mediaID: mediaID, publishingImmediately: true) { try $0.recordTranslationCancellation(batchID) }
                        } else {
                            try updateMedia(taskID: taskID, mediaID: mediaID, publishingImmediately: true) { try $0.recordTranslationFailure(batchID, reason: error.localizedDescription) }
                        }
                        return
                    }
                    translationRetryWait = nil
                }
            }
            guard let outputs else { throw CheckpointError.staleResult }
            do {
                try updateMedia(taskID: taskID, mediaID: mediaID) { try $0.commitTranslationBatch(batchID, outputs: outputs) }
            } catch let error as CheckpointError {
                try updateMedia(taskID: taskID, mediaID: mediaID, publishingImmediately: true) { try $0.recordTranslationFailure(batchID, reason: error.localizedDescription) }
                return
            }
        }
    }

    @discardableResult
    private func updateMedia<Result>(taskID: UUID, mediaID: UUID, publishingImmediately: Bool = false, mutation: (inout TaskMediaItem) throws -> Result) throws -> Result {
        try library.commitCheckpoint(taskID: taskID, publishingImmediately: publishingImmediately) { task in
            guard let index = task.items.firstIndex(where: { $0.id == mediaID }) else { throw CheckpointError.unknownWork }
            return try mutation(&task.items[index])
        }
    }
}

public struct TranslationRetryWait {
    public let deadline: Date
    public let attempt: Int
    public let reason: String

    public func label(at date: Date) -> String {
        let seconds = max(0, ceil(deadline.timeIntervalSince(date)))
        return String(localized: "\(reason) \(seconds.formatted(.number.precision(.fractionLength(0)))) 秒后自动重试（\(attempt)／3）", bundle: voxlineLocalizationBundle)
    }
}

public enum QueueError: Error, LocalizedError, Equatable {
    case busy, noWork, unavailable(String)
    public var errorDescription: String? {
        switch self {
        case .busy: String(localized: "已有任务处理中，请等待处理或取消结束后再开始。", bundle: voxlineLocalizationBundle)
        case .noWork: String(localized: "没有可处理的媒体；已完成成果与已有校对字幕不会重跑。", bundle: voxlineLocalizationBundle)
        case .unavailable(let reason): reason
        }
    }
}
