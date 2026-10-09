import CoreML
import Foundation
import Synchronization
import VoxlineCore
import WhisperKit

/// One SDK worker writes window evidence; callbacks read snapshots through the same lock.
final class TranscriptionEvidenceSeeker: SegmentSeeking, Sendable {
    private let state = Mutex<[TranscriptionWindowEvidence]>([])
    private let decoding = Mutex<(text: String?, tokens: [Int]?, active: Bool)>((nil, nil, true))
    private let cancelled = Mutex<Bool>(false)
    let sourceOffsetSeconds: Double

    init(sourceStartMilliseconds: Int64) {
        sourceOffsetSeconds = Double(sourceStartMilliseconds) / 1000
    }

    var windows: [TranscriptionWindowEvidence] { state.withLock { $0 } }
    var partialDecode: (text: String?, tokens: [Int]?) { decoding.withLock { ($0.text, $0.tokens) } }
    var isCancelled: Bool { cancelled.withLock { $0 } }

    func cancel() { cancelled.withLock { $0 = true } }
    func stopProgress() { decoding.withLock { $0.active = false } }

    func recordProgress(text: String, tokens: [Int]) -> Bool {
        decoding.withLock {
            guard $0.active else { return false }
            $0.text = text
            $0.tokens = tokens
            return true
        }
    }

    func findSeekPointAndSegments(decodingResult: DecodingResult, options: DecodingOptions, allSegmentsCount: Int,
                                 currentSeek: Int, segmentSize: Int, sampleRate: Int, timeToken: Int,
                                 specialToken: Int, tokenizer: WhisperTokenizer) -> (Int, [TranscriptionSegment]?) {
        let result = SegmentSeeker().findSeekPointAndSegments(decodingResult: decodingResult, options: options,
            allSegmentsCount: allSegmentsCount, currentSeek: currentSeek, segmentSize: segmentSize,
            sampleRate: sampleRate, timeToken: timeToken, specialToken: specialToken, tokenizer: tokenizer)
        state.withLock {
            $0.append(TranscriptionWindowEvidence(seekFrame: currentSeek, frameCount: segmentSize,
                decodedText: decodingResult.text, decodedTokens: decodingResult.tokens, language: decodingResult.language,
                skippedAsNoSpeech: result.1 == nil,
                segmentsBeforeAlignment: (result.1 ?? []).map { Self.raw($0, offset: sourceOffsetSeconds) }))
        }
        decoding.withLock { $0.text = nil; $0.tokens = nil }
        return result
    }

    func addWordTimestamps(segments: [TranscriptionSegment], alignmentWeights: MLMultiArray, tokenizer: WhisperTokenizer,
                           seek: Int, segmentSize: Int, prependPunctuations: String, appendPunctuations: String,
                           lastSpeechTimestamp: Float, options: DecodingOptions,
                           timings: TranscriptionTimings) throws -> [TranscriptionSegment]? {
        if segments.isEmpty {
            state.withLock { $0[$0.count - 1].alignedSegments = [] }
            return []
        }
        // Restrict DTW input to real audio frames, before alignment, rather than clipping output timestamps.
        let cropped = try Self.validAudioColumns(alignmentWeights, frameCount: segmentSize)
        let aligned = try WordTimestampAligner.align(segments: segments, alignmentWeights: cropped,
            tokenizer: tokenizer, seek: seek, prependPunctuations: prependPunctuations,
            appendPunctuations: appendPunctuations,
            lastSpeechTimestamp: lastSpeechTimestamp)
        let raw = aligned.map { Self.raw($0, offset: sourceOffsetSeconds) }
        state.withLock { $0[$0.count - 1].alignedSegments = raw }
        guard aligned.map(\.text) == segments.map(\.text), aligned.map(\.tokens) == segments.map(\.tokens) else {
            throw WhisperTranscriptionError.invalidAlignment(String(localized: "词对齐改变了识别文本或词元。", bundle: voxlineLocalizationBundle))
        }
        let selected = try Self.selectTiming(segments: segments, aligned: aligned, offset: sourceOffsetSeconds,
            lower: sourceOffsetSeconds + Double(seek) / 16_000,
            upper: sourceOffsetSeconds + Double(seek + segmentSize) / 16_000)
        state.withLock { $0[$0.count - 1].usesSegmentTimings = selected.usesSegmentTimings }
        return selected.segments
    }

    /// Recover the entire window so original segment times cannot overlap adjacent aligned segments.
    static func selectTiming(segments: [TranscriptionSegment], aligned: [TranscriptionSegment], offset: Double,
                             lower: Double, upper: Double) throws -> (segments: [TranscriptionSegment], usesSegmentTimings: Bool) {
        var original = segments
        for index in original.indices { original[index].words = nil }
        let recovered = try requiresSegmentTimings(original: original.map { raw($0, offset: offset) },
            aligned: aligned.map { raw($0, offset: offset) }, lower: lower, upper: upper)
        return (recovered ? original : aligned, recovered)
    }

    /// The same selection is used during inference and when recovering saved recognition.
    static func requiresSegmentTimings(original: [RawTranscriptionSegment], aligned: [RawTranscriptionSegment],
                                       lower: Double, upper: Double) throws -> Bool {
        guard original.map(\.text) == aligned.map(\.text) else {
            throw WhisperTranscriptionError.invalidAlignment(String(localized: "词对齐改变了识别文本。", bundle: voxlineLocalizationBundle))
        }
        do {
            try validate(aligned, lower: lower, upper: upper)
            return false
        } catch WhisperTranscriptionError.invalidTiming {
            _ = try segmentTimingsWithinWindow(original, lower: lower, upper: upper)
            return true
        }
    }

    /// Decoder timestamps can include the padded tail of the 30-second model window.
    /// Intersect segment times with real audio; never invent a duration for collapsed text.
    static func segmentTimingsWithinWindow(_ segments: [RawTranscriptionSegment], lower: Double,
                                          upper: Double) throws -> [RawTranscriptionSegment] {
        let bounded = segments.map { segment in
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  segment.startSeconds.isFinite, segment.endSeconds.isFinite else { return segment }
            return RawTranscriptionSegment(startSeconds: max(lower, segment.startSeconds),
                endSeconds: min(upper, segment.endSeconds), text: segment.text, words: nil,
                averageLogProbability: segment.averageLogProbability,
                noSpeechProbability: segment.noSpeechProbability, timingSource: segment.timingSource)
        }
        try validate(bounded, lower: lower, upper: upper)
        return bounded
    }

    static func selectedSegments(windows: [TranscriptionWindowEvidence], offset: Double) throws -> [RawTranscriptionSegment] {
        try windows.flatMap { window in
            if window.usesSegmentTimings == true {
                return try segmentTimingsWithinWindow(window.segmentsBeforeAlignment,
                    lower: offset + Double(window.seekFrame) / 16_000,
                    upper: offset + Double(window.seekFrame + window.frameCount) / 16_000)
            }
            return window.alignedSegments ?? window.segmentsBeforeAlignment
        }
    }

    static func raw(_ segment: TranscriptionSegment, offset: Double) -> RawTranscriptionSegment {
        RawTranscriptionSegment(startSeconds: offset + Double(segment.start), endSeconds: offset + Double(segment.end),
            text: segment.text, words: segment.words.map { words in
                words.map { RawWordTiming(text: $0.word, startSeconds: offset + Double($0.start),
                    endSeconds: offset + Double($0.end), probability: Double($0.probability)) }
            }, averageLogProbability: Double(segment.avgLogprob), noSpeechProbability: Double(segment.noSpeechProb))
    }

    static func validAudioColumns(_ weights: MLMultiArray, frameCount: Int) throws -> MLMultiArray {
        let shape = weights.shape.map(\.intValue)
        let strides = weights.strides.map(\.intValue)
        let samplesPerColumn = 320 // Pinned Whisper model: one alignment column per 20 ms.
        guard shape.count == 2, strides.count == 2, strides[1] == 1,
              shape[0] > 0, shape[1] > 0, frameCount >= samplesPerColumn else {
            throw WhisperTranscriptionError.invalidAlignment(String(localized: "对齐矩阵或实际音频窗口不足一个 20 毫秒帧。", bundle: voxlineLocalizationBundle))
        }
        // The pinned model emits Float16 weights; copy its logical rows before alignment.
        guard weights.dataType == .float16 else {
            throw WhisperTranscriptionError.invalidAlignment(String(localized: "固定 SDK 的词对齐只支持 Float16 权重。", bundle: voxlineLocalizationBundle))
        }
        let columns = min(shape[1], frameCount / samplesPerColumn)
        let cropped = try MLMultiArray(shape: [shape[0], columns] as [NSNumber], dataType: .float16)
        let destinationStride = cropped.strides[0].intValue
        for row in 0..<shape[0] {
            memcpy(cropped.dataPointer.advanced(by: row * destinationStride * MemoryLayout<Float16>.stride),
                   weights.dataPointer.advanced(by: row * strides[0] * MemoryLayout<Float16>.stride),
                   columns * MemoryLayout<Float16>.stride)
        }
        return cropped
    }

    static func validate(_ segments: [RawTranscriptionSegment], lower: Double, upper: Double) throws {
        // Invalid confidence must not be hidden by recovering an earlier timing failure.
        for segment in segments {
            if let probability = segment.averageLogProbability, !probability.isFinite {
                throw WhisperTranscriptionError.invalidAlignment(String(localized: "识别段平均置信度无效。", bundle: voxlineLocalizationBundle))
            }
            if let probability = segment.noSpeechProbability, !probability.isFinite || !(0...1).contains(probability) {
                throw WhisperTranscriptionError.invalidAlignment(String(localized: "识别段静音概率无效。", bundle: voxlineLocalizationBundle))
            }
            guard (segment.words ?? []).allSatisfy({ $0.probability.isFinite && (0...1).contains($0.probability) }) else {
                throw WhisperTranscriptionError.invalidAlignment(String(localized: "词置信度无效。", bundle: voxlineLocalizationBundle))
            }
        }
        var previousEnd = lower - 0.02
        for segment in segments {
            if let words = segment.words, !words.isEmpty {
                let wordText = words.map(\.text).joined().precomposedStringWithCanonicalMapping.filter { !$0.isWhitespace }
                let segmentText = segment.text.precomposedStringWithCanonicalMapping.filter { !$0.isWhitespace }
                guard wordText == segmentText else {
                    throw WhisperTranscriptionError.invalidTiming(String(localized: "词对齐文本与原始段不一致，保留段时间供校对。", bundle: voxlineLocalizationBundle))
                }
            }
            // Empty model evidence remains in the report; it is never exported as a subtitle cue.
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard segment.startSeconds.isFinite, segment.endSeconds.isFinite,
                  segment.startSeconds >= lower - 0.02, segment.endSeconds <= upper + 0.02,
                  segment.endSeconds > segment.startSeconds, segment.startSeconds >= previousEnd else {
                throw WhisperTranscriptionError.invalidTiming(String(localized: "非空识别段时间无效、回退、重叠或越过实际窗口；原文保留为待校时证据。", bundle: voxlineLocalizationBundle))
            }
            previousEnd = segment.endSeconds
            var previousWordEnd = lower - 0.02
            for word in segment.words ?? [] {
                guard word.startSeconds.isFinite, word.endSeconds.isFinite, word.startSeconds >= lower - 0.02,
                      word.endSeconds <= upper + 0.02, word.endSeconds >= word.startSeconds,
                      word.startSeconds >= previousWordEnd else {
                    throw WhisperTranscriptionError.invalidTiming(String(localized: "词时间无效；原文保留为待校时证据。", bundle: voxlineLocalizationBundle))
                }
                previousWordEnd = word.endSeconds
            }
        }
    }

    static func validatedSegments(windows evidence: [TranscriptionWindowEvidence], sourceOffsetSeconds: Double,
                                  frameCount: Int, returnedSegments: [RawTranscriptionSegment]) throws -> [RawTranscriptionSegment] {
        var coveredThrough = 0
        var previousSeek = -1
        for window in evidence {
            guard window.seekFrame > previousSeek, window.seekFrame <= coveredThrough,
                  window.frameCount > 0, window.frameCount <= 480_000,
                  window.seekFrame + window.frameCount <= frameCount else {
                throw WhisperTranscriptionError.invalidAlignment(String(localized: "推理窗口回退、缺失或越过音频范围。", bundle: voxlineLocalizationBundle))
            }
            previousSeek = window.seekFrame
            coveredThrough = max(coveredThrough, window.seekFrame + window.frameCount)
        }
        guard coveredThrough == frameCount else {
            throw WhisperTranscriptionError.invalidAlignment(String(localized: "推理未覆盖完整输入音频。", bundle: voxlineLocalizationBundle))
        }
        let raw = evidence.flatMap { window in
            window.usesSegmentTimings == true ? window.segmentsBeforeAlignment :
                (window.alignedSegments ?? window.segmentsBeforeAlignment)
        }
        let selected = try selectedSegments(windows: evidence, offset: sourceOffsetSeconds)
        // The SDK filters zero-duration segments. Fail if any nonempty evidence was lost in that path.
        let returned = returnedSegments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard raw.filter({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) == returned ||
                selected.filter({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) == returned else {
            throw WhisperTranscriptionError.invalidAlignment(String(localized: "SDK 输出遗漏或改变了非空识别证据。", bundle: voxlineLocalizationBundle))
        }
        try Self.validate(selected, lower: sourceOffsetSeconds, upper: sourceOffsetSeconds + Double(frameCount) / 16_000)
        return selected
    }
}
