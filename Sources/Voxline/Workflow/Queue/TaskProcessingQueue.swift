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
    private var queuedIDs = Set<UUID>()
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
        let selectedIDs = Set(ids)
        try library.commitCheckpoint(taskID: taskID) { current in
            for index in current.items.indices where selectedIDs.contains(current.items[index].id) {
                if case .running = current.items[index].status { throw CheckpointError.workRunning }
                current.items[index].status = .pending
            }
            if current.startedAt == nil { try current.recordStart() }
        }
        beginRun(taskID: taskID, parameters: task.parameters, mediaIDs: ids)
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

    public func startRetranslation(taskID: UUID, mediaID: UUID, cueIDs: [UUID]) throws {
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
        let batches = try SubtitleTranslationBatchPlanner.batches(cues: item.cues, pendingIDs: cueIDs, targetLanguage: settings.targetLanguage, batchSize: settings.batchSize)
        let batchIDs = try updateMedia(taskID: taskID, mediaID: mediaID) { current in
            try current.prepareTranslationBatches(cueIDBatches: batches)
        }
        beginRun(taskID: taskID, parameters: task.parameters, mediaIDs: [mediaID], translationBatchIDs: batchIDs)
    }

    /// Both entry points acquire the same execution lifetime after their checkpoint is saved.
    private func beginRun(taskID: UUID, parameters: TaskParameters, mediaIDs: [UUID], translationBatchIDs: [UUID]? = nil) {
        self.taskID = taskID
        library.protectedTaskID = taskID
        queuedIDs = Set(mediaIDs)
        cancelledIDs = []
        stopRequested = false
        isCancelling = false
        errorMessage = nil
        worker = Task { await self.consume(taskID: taskID, parameters: parameters, mediaIDs: mediaIDs, translationBatchIDs: translationBatchIDs) }
    }

    private func consume(taskID: UUID, parameters: TaskParameters, mediaIDs: [UUID], translationBatchIDs: [UUID]? = nil) async {
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
            queuedIDs = []
            cancelledIDs = []
            isCancelling = false
            onFinish?()
        }
        for id in mediaIDs {
            queuedIDs.remove(id)
            if stopRequested { break }
            if cancelledIDs.contains(id) { continue }
            mediaID = id
            isCancelling = false
            let operation = Task {
                if let translationBatchIDs {
                    guard let settings = parameters.translation else { throw QueueError.unavailable(String(localized: "本次任务未配置翻译服务。", bundle: voxlineLocalizationBundle)) }
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
            catch { errorMessage = library.errorMessage ?? error.localizedDescription }
            mediaWork = nil
            progressID = nil
        }
    }

    private func transcribeMedia(taskID: UUID, mediaID: UUID, parameters: TaskParameters) async throws {
        guard let item = library.task(for: taskID)?.items.first(where: { $0.id == mediaID }),
              let media = item.media else { throw CheckpointError.taskUnavailable }
        if item.hasCompletedTranscription {
            if let translation = parameters.translation {
                try await translateMedia(taskID: taskID, mediaID: mediaID, settings: translation)
            } else {
                try updateMedia(taskID: taskID, mediaID: mediaID) { $0.status = .completed }
            }
            return
        }
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
                    case .cacheInvalidated: self.progressText = String(localized: "正在提取音频", bundle: voxlineLocalizationBundle)
                    }
                }
            }
            let proposed = try await pipeline.speechChunks(from: extracted, settings: parameters.transcription)
            let completedRanges = item.checkpoint?.chunks.filter(\.isCompleted).map(\.range) ?? []
            var completedIndex = 0
            var remaining: [TranscriptionAudio] = []
            for input in proposed {
                let end = input.sourceStartMilliseconds + input.durationMilliseconds
                var start = input.sourceStartMilliseconds
                while completedIndex < completedRanges.count {
                    let completed = completedRanges[completedIndex]
                    let completedEnd = completed.sourceStartMilliseconds + completed.durationMilliseconds
                    if completedEnd <= start { completedIndex += 1; continue }
                    if completed.sourceStartMilliseconds >= end { break }
                    if start < completed.sourceStartMilliseconds {
                        remaining.append(try TranscriptionAudioSlicer.slice(input, range: .init(
                            sourceStartMilliseconds: start, durationMilliseconds: completed.sourceStartMilliseconds - start)))
                    }
                    start = max(start, completedEnd)
                    if start >= end { break }
                }
                if start < end {
                    remaining.append(try TranscriptionAudioSlicer.slice(input, range: .init(
                        sourceStartMilliseconds: start, durationMilliseconds: end - start)))
                }
            }
            audio = remaining
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
                else { try item.reconcileTranscriptionChunks(ranges: ranges) }
                guard let checkpoint = item.checkpoint else { throw CheckpointError.missingCheckpoint }
                return try item.recoveryPlan(media: media, parameters: parameters, ranges: checkpoint.chunks.map(\.range)).transcriptionChunkIDs
            }
        } catch let error as CheckpointError {
            try updateMedia(taskID: taskID, mediaID: mediaID, publishingImmediately: true) { $0.status = .failed(reason: error.localizedDescription) }
            return
        }
        var audioByRange: [TranscriptionChunkRange: TranscriptionAudio] = [:]
        for (index, range) in ranges.enumerated() {
            guard audioByRange.updateValue(audio[index], forKey: range) == nil else { throw CheckpointError.invalidRecord }
        }
        guard let plannedChunks = library.task(for: taskID)?.items.first(where: { $0.id == mediaID })?.checkpoint?.chunks else {
            throw CheckpointError.missingCheckpoint
        }
        var chunkPositions: [UUID: Int] = [:]
        for (position, chunk) in plannedChunks.enumerated() {
            guard chunkPositions.updateValue(position, forKey: chunk.id) == nil else { throw CheckpointError.invalidRecord }
        }
        for chunkID in chunkIDs {
            if Task.isCancelled {
                try updateMedia(taskID: taskID, mediaID: mediaID, publishingImmediately: true) { $0.status = .cancelled }
                return
            }
            guard let chunks = library.task(for: taskID)?.items.first(where: { $0.id == mediaID })?.checkpoint?.chunks,
                  let index = chunkPositions[chunkID], chunks.indices.contains(index), chunks[index].id == chunkID,
                  let input = audioByRange[chunks[index].range] else { throw CheckpointError.unknownWork }
            let savedRecognition: TranscriptionEvidence?
            switch chunks[index].state {
            case .failed(_, let evidence), .cancelled(let evidence):
                if let evidence, evidence.settings == parameters.transcription,
                   evidence.cloudResult != nil || WhisperKitTranscriptionProvider.hasCompleteRecognition(evidence) {
                    savedRecognition = evidence
                } else { savedRecognition = nil }
            default: savedRecognition = nil
            }
            let sourceID = try updateMedia(taskID: taskID, mediaID: mediaID) { try $0.beginTranscriptionChunk(chunkID, at: index) }
            let decodingID = UUID()
            progressID = decodingID
            progressText = String(localized: "正在转写 \(Int(Double(index) / Double(chunks.count) * 100))%", bundle: voxlineLocalizationBundle)
            let evidence: TranscriptionEvidence
            do {
                if let savedRecognition {
                    evidence = try savedRecognition.cloudResult != nil
                        ? CloudTranscriptionAlignment.completedEvidence(from: savedRecognition)
                        : WhisperKitTranscriptionProvider.recoverCompletedEvidence(savedRecognition)
                } else {
                    evidence = try await pipeline.transcribe(mediaID: mediaID, audio: input, settings: parameters.transcription) { progress in
                        Task { @MainActor in
                            guard self.progressID == decodingID else { return }
                            let detail: String
                            switch progress {
                            case .uploadingAudio: detail = String(localized: "正在上传音频", bundle: voxlineLocalizationBundle)
                            case .awaitingTranscription: detail = String(localized: "等待转写服务", bundle: voxlineLocalizationBundle)
                            case .retryingAudio(let attempt, let delay): detail = String(localized: "转写重试 \(attempt)／3，等待 \(Int(delay.rounded(.up))) 秒", bundle: voxlineLocalizationBundle)
                            case .readingAudio: detail = String(localized: "读取音频", bundle: voxlineLocalizationBundle)
                            case .loadingModel: detail = String(localized: "正在准备转写", bundle: voxlineLocalizationBundle)
                            case .detectingLanguage: detail = String(localized: "识别语言", bundle: voxlineLocalizationBundle)
                            case .decoding: detail = String(localized: "正在转写", bundle: voxlineLocalizationBundle)
                            case .completed: detail = String(localized: "正在保存字幕", bundle: voxlineLocalizationBundle)
                            }
                            self.progressText = String(localized: "\(detail) · \(Int(Double(index) / Double(chunks.count) * 100))%", bundle: voxlineLocalizationBundle)
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
                    try $0.recordTranscriptionFailure(chunkID, sourceID: sourceID, reason: error.localizedDescription, evidence: evidence, at: index)
                }
                continue
            }
            // Saving is outside the Provider catch: I/O failure must stop the queue rather than be
            // mistaken for a failed inference and allow later work to overwrite unsaved results.
            do {
                try updateMedia(taskID: taskID, mediaID: mediaID) { try $0.commitTranscriptionChunk(chunkID, result: result, at: index) }
            } catch let error as DomainValidationError {
                // A newly submitted range can conflict with manual timing. Keep the edit and the
                // raw inference, fail this range, and let the other media continue.
                try updateMedia(taskID: taskID, mediaID: mediaID, publishingImmediately: true) {
                    try $0.recordTranscriptionFailure(chunkID, sourceID: sourceID, reason: error.localizedDescription, evidence: evidence, at: index)
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
            try updateMedia(taskID: taskID, mediaID: mediaID, publishingImmediately: true) { $0.status = .cancelled }
            return
        }
        let plan = try item.recoveryPlan(media: checkpoint.media, parameters: checkpoint.parameters, ranges: checkpoint.chunks.map(\.range))
        let newBatches: [[UUID]]
        do {
            newBatches = try SubtitleTranslationBatchPlanner.batches(cues: item.cues, pendingIDs: plan.untranslatedCueIDs,
                targetLanguage: settings.targetLanguage, batchSize: settings.batchSize)
        } catch {
            try updateMedia(taskID: taskID, mediaID: mediaID, publishingImmediately: true) { $0.status = .failed(reason: error.localizedDescription) }
            return
        }
        let batchIDs = try updateMedia(taskID: taskID, mediaID: mediaID) { item in
            try plan.translationBatchIDs + item.prepareTranslationBatches(cueIDBatches: newBatches)
        }
        if batchIDs.isEmpty {
            try updateMedia(taskID: taskID, mediaID: mediaID) {
                $0.status = $0.cues.allSatisfy(\.hasTranslation) ? .completed : .needsTranslation
            }
            return
        }
        try await translateBatches(taskID: taskID, mediaID: mediaID, settings: settings, batchIDs: batchIDs)
    }

    private func translateBatches(taskID: UUID, mediaID: UUID, settings: TranslationSettings, batchIDs: [UUID]) async throws {
        defer { translationRetryWait = nil }
        guard let initial = library.task(for: taskID)?.items.first(where: { $0.id == mediaID }) else { throw CheckpointError.taskUnavailable }
        let workIndex = try TranslationCheckpointIndex(item: initial)
        for batchID in batchIDs {
            if Task.isCancelled {
                try updateMedia(taskID: taskID, mediaID: mediaID, publishingImmediately: true) { $0.status = .cancelled }
                return
            }
            let request: SubtitleTranslationRequest
            do {
                request = try updateMedia(taskID: taskID, mediaID: mediaID) { item in
                    let batch = try item.beginTranslationBatch(batchID, using: workIndex)
                    return try SubtitleTranslationRequest(inputs: batch.inputs, cues: item.cues,
                        cuePosition: { workIndex.cuePosition($0, in: item.cues) })
                }
            } catch let error as CheckpointError {
                try updateMedia(taskID: taskID, mediaID: mediaID, publishingImmediately: true) { $0.status = .failed(reason: error.localizedDescription) }
                return
            }
            guard let current = library.task(for: taskID)?.items.first(where: { $0.id == mediaID }) else { throw CheckpointError.taskUnavailable }
            progressText = String(localized: "正在翻译 \(current.cues.isEmpty ? 100 : current.cues.filter(\.hasTranslation).count * 100 / current.cues.count)%", bundle: voxlineLocalizationBundle)
            var outputs: [TranslationBatchOutput]?
            var retries = 0
            while outputs == nil {
                do {
                    try Task.checkCancellation()
                    if retries > 0 {
                        guard let latest = library.task(for: taskID)?.items.first(where: { $0.id == mediaID }),
                              request.inputs.allSatisfy({ input in
                                  workIndex.cuePosition(input.cueID, in: latest.cues).map { input.matches(latest.cues[$0]) } == true
                              }) else {
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
                try updateMedia(taskID: taskID, mediaID: mediaID) { try $0.commitTranslationBatch(batchID, outputs: outputs, using: workIndex) }
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
