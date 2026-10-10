import Foundation

public struct SubtitleSegmentationPolicy: Codable, Equatable, Sendable {
    public let maximumWidth: Int
    public let maximumDurationMilliseconds: Int64
    public let minimumDurationMilliseconds: Int64
    public let silenceMilliseconds: Int64

    public init(maximumWidth: Int = 40, maximumDurationMilliseconds: Int64 = 8000,
                minimumDurationMilliseconds: Int64 = 1000, silenceMilliseconds: Int64 = 500) {
        self.maximumWidth = maximumWidth
        self.maximumDurationMilliseconds = maximumDurationMilliseconds
        self.minimumDurationMilliseconds = minimumDurationMilliseconds
        self.silenceMilliseconds = silenceMilliseconds
    }

    public static let readable = Self()
}

/// An inference result is validated at commit; only its source and editable cues enter the document.
public struct SubtitleSegmentationResult: Codable, Equatable, Sendable {
    public let sourceID: UUID
    public let evidence: TranscriptionEvidence
    public let policy: SubtitleSegmentationPolicy
    public let entries: [SegmentedSubtitle]
    public let excludedEmptySegmentIndices: [Int]
    public var cues: [SubtitleCue] { entries.map(\.cue) }
}

public struct SegmentedSubtitle: Codable, Equatable, Sendable {
    public enum Alignment: String, Codable, Sendable { case words, segment }
    public enum ReviewReason: String, Codable, Sendable {
        case missingWordTiming, exceedsWidth, exceedsDuration, shortDisplay
    }

    public let cue: SubtitleCue
    public let segmentIndex: Int
    public let wordRange: Range<Int>?
    public let alignment: Alignment
    public let reviewReasons: [ReviewReason]
}

public enum SubtitleSegmentationError: Error, LocalizedError, Equatable {
    case invalidPolicy, invalidRange, incompleteTranscription
    case invalidSegment(Int), invalidWords(Int), textMismatch(Int), invalidCueTiming(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidPolicy: String(localized: "字幕切分参数无效。", bundle: voxlineLocalizationBundle)
        case .invalidRange: String(localized: "字幕切分的源范围无效或超出媒体。", bundle: voxlineLocalizationBundle)
        case .incompleteTranscription: String(localized: "转写未完成，请保留失败证据并重新识别或人工校时。", bundle: voxlineLocalizationBundle)
        case .invalidSegment(let index): String(localized: "第 \(index + 1) 个原始段时间无效、重叠或越界，需重新识别或人工校时。", bundle: voxlineLocalizationBundle)
        case .invalidWords(let index): String(localized: "第 \(index + 1) 个原始段词时间无效、重叠或越界，需重新识别或人工校时。", bundle: voxlineLocalizationBundle)
        case .textMismatch(let index): String(localized: "第 \(index + 1) 个原始段与词文本不一致，不能生成遗漏原文的字幕。", bundle: voxlineLocalizationBundle)
        case .invalidCueTiming(let index): String(localized: "第 \(index + 1) 个原始段不能生成有效的毫秒字幕时间，需人工校时。", bundle: voxlineLocalizationBundle)
        }
    }
}

public enum SubtitleSegmenter {
    public static func segment(_ evidence: TranscriptionEvidence, sourceID: UUID,
                               mediaDurationMilliseconds: Int64,
                               policy: SubtitleSegmentationPolicy = .readable) throws -> SubtitleSegmentationResult {
        guard policy.maximumWidth > 0, policy.maximumDurationMilliseconds > 0,
              policy.minimumDurationMilliseconds > 0,
              policy.minimumDurationMilliseconds <= policy.maximumDurationMilliseconds,
              policy.silenceMilliseconds > 0 else { throw SubtitleSegmentationError.invalidPolicy }
        guard evidence.outcome == .completed, evidence.failureReason == nil,
              evidence.partialDecodedText == nil, evidence.partialDecodedTokens == nil else {
            throw SubtitleSegmentationError.incompleteTranscription
        }
        let (rangeEnd, overflow) = evidence.sourceStartMilliseconds.addingReportingOverflow(evidence.durationMilliseconds)
        guard !overflow, evidence.sourceStartMilliseconds >= 0, evidence.durationMilliseconds > 0,
              rangeEnd <= mediaDurationMilliseconds else { throw SubtitleSegmentationError.invalidRange }
        let lower = Double(evidence.sourceStartMilliseconds) / 1000
        let upper = Double(rangeEnd) / 1000
        var previousSegmentEnd = lower
        var previousSpeechEnd = lower
        var entries: [SegmentedSubtitle] = []
        var excluded: [Int] = []

        for (segmentIndex, raw) in evidence.segments.enumerated() {
            if raw.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard raw.words?.allSatisfy({ $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) != false else {
                    throw SubtitleSegmentationError.textMismatch(segmentIndex)
                }
                excluded.append(segmentIndex)
                continue
            }
            // A decoder may timestamp a tail segment to the end of its padded window.
            // Keep its text and intersect with actual input; raw evidence remains unchanged.
            guard raw.startSeconds.isFinite, raw.endSeconds.isFinite,
                  raw.startSeconds >= previousSegmentEnd - 0.05 else { throw SubtitleSegmentationError.invalidSegment(segmentIndex) }
            let segmentStart = max(previousSegmentEnd, raw.startSeconds)
            let segmentEnd = min(upper, raw.endSeconds)
            guard segmentEnd > segmentStart else { throw SubtitleSegmentationError.invalidSegment(segmentIndex) }
            previousSegmentEnd = segmentEnd

            guard let words = raw.words, !words.isEmpty else {
                guard segmentStart >= previousSpeechEnd else { throw SubtitleSegmentationError.invalidSegment(segmentIndex) }
                previousSpeechEnd = segmentEnd
                let cue = try timedCue(sourceID: sourceID, segmentIndex: segmentIndex, wordIndex: nil,
                                       start: segmentStart, end: segmentEnd, text: raw.text)
                entries.append(SegmentedSubtitle(cue: cue, segmentIndex: segmentIndex, wordRange: nil,
                                                 alignment: .segment, reviewReasons: [.missingWordTiming]))
                continue
            }
            guard textContent(words.map(\.text).joined()) == textContent(raw.text) else {
                throw SubtitleSegmentationError.textMismatch(segmentIndex)
            }
            for word in words {
                guard word.startSeconds.isFinite, word.endSeconds.isFinite,
                      word.startSeconds >= previousSpeechEnd - 0.05, word.endSeconds >= word.startSeconds,
                      word.startSeconds >= lower - 0.05, word.endSeconds <= upper + 0.05 else {
                    throw SubtitleSegmentationError.invalidWords(segmentIndex)
                }
                previousSpeechEnd = min(upper, max(previousSpeechEnd, word.endSeconds))
            }

            var start = 0
            while start < words.count {
                var end = start
                var width = 0
                var preferredEnd: Int?
                while end < words.count {
                    let candidateWidth = width + visualWidth(words[end].text)
                    let duration = (words[end].endSeconds - words[start].startSeconds) * 1000
                    let boundaryBefore = end > start && isWordBoundary(after: words[end - 1].text, before: words[end].text)
                    if boundaryBefore, (candidateWidth > policy.maximumWidth || duration > Double(policy.maximumDurationMilliseconds)),
                       words[end - 1].endSeconds > words[start].startSeconds {
                        end = preferredEnd ?? end
                        break
                    }
                    width = candidateWidth
                    end += 1
                    let positiveDuration = words[end - 1].endSeconds > words[start].startSeconds
                    let boundaryAfter = end == words.count || isWordBoundary(after: words[end - 1].text, before: words[end].text)
                    if positiveDuration, boundaryAfter {
                        let punctuation = finalPunctuation(words[end - 1].text)
                        if punctuation == .sentence { break }
                        if end < words.count,
                           (words[end].startSeconds - words[end - 1].endSeconds) * 1000 >= Double(policy.silenceMilliseconds) { break }
                        if punctuation == .pause {
                            preferredEnd = end
                            if width >= policy.maximumWidth / 2 || duration >= 2500 { break }
                        }
                    }
                }
                // A trailing zero-duration word belongs to the preceding timed speech.
                // Width or punctuation splitting must not leave it as an unrenderable cue.
                while end < words.count, words[end].startSeconds == words[end].endSeconds,
                      words[end].startSeconds == words[end - 1].endSeconds {
                    end += 1
                }
                let cue = try timedCue(sourceID: sourceID, segmentIndex: segmentIndex, wordIndex: start,
                                       start: words[start].startSeconds, end: words[end - 1].endSeconds,
                                       text: words[start..<end].map(\.text).joined())
                entries.append(SegmentedSubtitle(cue: cue, segmentIndex: segmentIndex, wordRange: start..<end,
                                                 alignment: .words, reviewReasons: []))
                start = end
            }
        }

        // Extend display only into available silence. Actual speech endpoints remain in the evidence.
        for index in entries.indices {
            let original = entries[index]
            var cue = original.cue
            cue.startMilliseconds = max(evidence.sourceStartMilliseconds, cue.startMilliseconds,
                                        index > 0 ? entries[index - 1].cue.endMilliseconds : evidence.sourceStartMilliseconds)
            cue.endMilliseconds = min(rangeEnd, cue.endMilliseconds)
            let nextStart = index + 1 < entries.count ? max(cue.startMilliseconds, entries[index + 1].cue.startMilliseconds) : rangeEnd
            if cue.endMilliseconds > nextStart, cue.endMilliseconds - nextStart <= 50 {
                cue.endMilliseconds = nextStart
            }
            guard cue.endMilliseconds > cue.startMilliseconds, cue.endMilliseconds <= nextStart else { throw SubtitleSegmentationError.invalidCueTiming(original.segmentIndex) }
            let duration = cue.endMilliseconds - cue.startMilliseconds
            if duration < policy.minimumDurationMilliseconds {
                cue.endMilliseconds += min(policy.minimumDurationMilliseconds - duration, nextStart - cue.endMilliseconds)
            }
            var reasons = original.reviewReasons
            if visualWidth(cue.sourceText) > policy.maximumWidth { reasons.append(.exceedsWidth) }
            if cue.endMilliseconds - cue.startMilliseconds > policy.maximumDurationMilliseconds { reasons.append(.exceedsDuration) }
            if cue.endMilliseconds - cue.startMilliseconds < policy.minimumDurationMilliseconds { reasons.append(.shortDisplay) }
            entries[index] = SegmentedSubtitle(cue: cue, segmentIndex: original.segmentIndex, wordRange: original.wordRange,
                                              alignment: original.alignment, reviewReasons: reasons)
        }
        try SubtitleCue.validateTimeline(entries.map(\.cue), within: nil)
        return SubtitleSegmentationResult(sourceID: sourceID, evidence: evidence, policy: policy,
                                          entries: entries, excludedEmptySegmentIndices: excluded)
    }

    /// The source ID identifies an immutable transcription chunk; the first source word anchors each cue.
    private static func timedCue(sourceID: UUID, segmentIndex: Int, wordIndex: Int?,
                                 start: Double, end: Double, text: String) throws -> SubtitleCue {
        guard segmentIndex <= 0xFFFFFF, wordIndex.map({ $0 < Int(UInt32.max) }) != false,
              start >= -0.05, end * 1000 < Double(Int64.max) else { throw SubtitleSegmentationError.invalidRange }
        var bytes = withUnsafeBytes(of: sourceID.uuid) { Array($0) }
        let anchor = (UInt64(segmentIndex) << 32) | UInt64(wordIndex.map(UInt32.init) ?? UInt32.max)
        // Preserve the UUID variant/version and use a bijection within the source namespace.
        for index in 0..<7 { bytes[index + 9] ^= UInt8(truncatingIfNeeded: anchor >> (index * 8)) }
        let id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                             bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        let startMilliseconds = Int64((start * 1000).rounded())
        let endMilliseconds = Int64((end * 1000).rounded())
        guard endMilliseconds > startMilliseconds, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SubtitleSegmentationError.invalidCueTiming(segmentIndex)
        }
        return try SubtitleCue(id: id, startMilliseconds: max(0, startMilliseconds), endMilliseconds: endMilliseconds,
                               sourceText: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func textContent(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.filter { !$0.isWhitespace }
    }

    /// CJK/full-width graphemes count as two columns; this is a text budget, not font measurement.
    static func visualWidth(_ text: String) -> Int {
        text.reduce(0) { width, character in
            width + (character.unicodeScalars.contains { scalar in
                (0x1100...0x11FF).contains(scalar.value) || (0x2E80...0xA4CF).contains(scalar.value) ||
                (0xAC00...0xD7AF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value) ||
                (0xFE10...0xFE6F).contains(scalar.value) || (0xFF01...0xFF60).contains(scalar.value) ||
                (0x1F300...0x1FAFF).contains(scalar.value) || (0x20000...0x3FFFF).contains(scalar.value)
            } ? 2 : 1)
        }
    }

    private static func isWordBoundary(after current: String, before next: String) -> Bool {
        guard let first = next.first else { return false }
        let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.allSatisfy({ $0.isPunctuation }) { return false }
        if first.isWhitespace { return true }
        return visualWidth(String(first)) == 2 || current.last.map { visualWidth(String($0)) == 2 } == true
    }

    private enum Punctuation { case sentence, pause, none }
    private static func finalPunctuation(_ text: String) -> Punctuation {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’）)]}"))
        guard let last = value.last else { return .none }
        if "。！？!?…".contains(last) { return .sentence }
        if last == ".", !["mr.", "mrs.", "ms.", "dr.", "prof.", "sr.", "jr.", "st.", "vs.", "etc.", "e.g.", "i.e."].contains(value.lowercased()),
           value.filter({ $0 == "." }).count == 1 { return .sentence }
        return "，,；;：:、".contains(last) ? .pause : .none
    }
}
