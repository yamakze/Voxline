// Adapted from Argmax SegmentSeeker (MIT, Copyright © 2024 Argmax, Inc.).
// License: Licenses/Argmax-LICENSE.txt. Keep the pinned SDK's alignment rules,
// but read logical matrix indices instead of copying packed rows into an IOSurface.
import CoreML
import Foundation
import WhisperKit

enum WordTimestampAligner {
    static func align(segments: [TranscriptionSegment], alignmentWeights: MLMultiArray,
                      tokenizer: WhisperTokenizer, seek: Int,
                      prependPunctuations: String, appendPunctuations: String,
                      lastSpeechTimestamp: Float) throws -> [TranscriptionSegment] {
        let tokens = segments.flatMap(\.tokens)
        var logProbabilities = [Float]()
        for segment in segments {
            guard segment.tokens.count == segment.tokenLogProbs.count else {
                throw WhisperTranscriptionError.invalidAlignment(String(localized: "词元与置信度数量不符。", bundle: voxlineLocalizationBundle))
            }
            for (token, probabilities) in zip(segment.tokens, segment.tokenLogProbs) {
                guard let probability = probabilities[token], probability.isFinite else {
                    throw WhisperTranscriptionError.invalidAlignment(String(localized: "词元置信度缺失或无效。", bundle: voxlineLocalizationBundle))
                }
                logProbabilities.append(probability)
            }
        }
        let path = try dynamicTimeWarping(alignmentWeights, tokenCount: tokens.count)
        guard let lastStep = path.last else {
            throw WhisperTranscriptionError.invalidAlignment(String(localized: "词对齐路径为空。", bundle: voxlineLocalizationBundle))
        }
        let (words, wordTokens) = tokenizer.splitToWordTokens(tokenIds: tokens)
        var alignment = [WordTiming]()
        if wordTokens.count > 1 {
            var starts: [Float] = [0]
            var ends = [Float]()
            var previousToken = path.first?.token ?? 0
            for step in path where step.token != previousToken {
                previousToken = step.token
                let time = Float(step.column) * Float(WhisperKit.secondsPerTimeToken)
                starts.append(time)
                ends.append(time)
            }
            ends.append(Float(lastStep.column) * Float(WhisperKit.secondsPerTimeToken))
            guard starts.count == tokens.count, ends.count == tokens.count,
                  wordTokens.flatMap({ $0 }) == tokens, words.count == wordTokens.count else {
                throw WhisperTranscriptionError.invalidAlignment(String(localized: "词对齐未完整覆盖识别词元。", bundle: voxlineLocalizationBundle))
            }
            var offset = 0
            for (word, group) in zip(words, wordTokens) {
                guard !group.isEmpty else {
                    throw WhisperTranscriptionError.invalidAlignment(String(localized: "分词返回空词元组。", bundle: voxlineLocalizationBundle))
                }
                let end = offset + group.count
                let probability = exp(logProbabilities[offset..<end].reduce(0, +) / Float(group.count))
                alignment.append(WordTiming(word: word, tokens: group, start: starts[offset],
                    end: ends[end - 1], probability: probability))
                offset = end
            }
        }
        let seeker = SegmentSeeker()
        let durations = seeker.calculateWordDurationConstraints(alignment: alignment)
        alignment = seeker.truncateLongWordsAtSentenceBoundaries(alignment, maxDuration: durations.max)
        alignment = mergedPunctuations(alignment, prepended: prependPunctuations, appended: appendPunctuations)
        return seeker.updateSegmentsWithWordTimings(segments: segments, mergedAlignment: alignment,
            seek: seek, lastSpeechTimestamp: lastSpeechTimestamp, constrainedMedianDuration: durations.median,
            maxDuration: durations.max, tokenizer: tokenizer)
    }

    /// Same path and tie rules as the pinned SDK. Logical indexing respects row padding.
    static func dynamicTimeWarping(_ matrix: MLMultiArray, tokenCount: Int) throws -> [(token: Int, column: Int)] {
        let shape = matrix.shape.map(\.intValue)
        guard shape.count == 2, tokenCount > 0, tokenCount <= shape[0], shape[1] > 0 else {
            throw WhisperTranscriptionError.invalidAlignment(String(localized: "对齐矩阵未覆盖识别词元。", bundle: voxlineLocalizationBundle))
        }
        let columns = shape[1]
        // Convert once through Core ML, preserving logical rows (including IOSurface padding).
        // Per-cell MLMultiArray subscripting boxes indices and values in this hot loop.
        let weights = MLMultiArray(concatenating: [matrix], axis: 0, dataType: .double)
        return try weights.withUnsafeBufferPointer(ofType: Double.self) { values in
            let strides = weights.strides.map(\.intValue)
            var previous = [Double](repeating: .infinity, count: columns + 1)
            var current = previous
            previous[0] = 0
            var trace = [UInt8](repeating: 2, count: (tokenCount + 1) * (columns + 1))
            for row in 1...tokenCount {
                trace[row * (columns + 1)] = 1
                current[0] = .infinity
                for column in 1...columns {
                    let weight = values[(row - 1) * strides[0] + (column - 1) * strides[1]]
                    guard weight.isFinite else {
                        throw WhisperTranscriptionError.invalidAlignment(String(localized: "词对齐权重无效。", bundle: voxlineLocalizationBundle))
                    }
                    let diagonal = previous[column - 1]
                    let up = previous[column]
                    let left = current[column - 1]
                    let cost: Double
                    let direction: UInt8
                    if diagonal < up && diagonal < left { cost = diagonal; direction = 0 }
                    else if up < diagonal && up < left { cost = up; direction = 1 }
                    else { cost = left; direction = 2 }
                    current[column] = cost - weight
                    trace[row * (columns + 1) + column] = direction
                }
                swap(&previous, &current)
            }
            var row = tokenCount
            var column = columns
            var path = [(token: Int, column: Int)]()
            while row > 0 || column > 0 {
                path.append((row - 1, column - 1))
                switch trace[row * (columns + 1) + column] {
                case 0: row -= 1; column -= 1
                case 1: row -= 1
                default: column -= 1
                }
            }
            return Array(path.reversed())
        }
    }

    private static func mergedPunctuations(_ alignment: [WordTiming], prepended: String,
                                           appended: String) -> [WordTiming] {
        var prefixed = [WordTiming]()
        for var word in alignment {
            if let previous = prefixed.last,
               previous.word.unicodeScalars.first.map(CharacterSet.whitespaces.contains) == true,
               prepended.contains(previous.word.trimmingCharacters(in: .whitespaces)) {
                word.word = previous.word + word.word
                word.tokens = previous.tokens + word.tokens
                prefixed.removeLast()
            }
            prefixed.append(word)
        }
        var result = [WordTiming]()
        for word in prefixed {
            if let previous = result.last, !previous.word.hasSuffix(" "), appended.contains(word.word) {
                result[result.count - 1].word += word.word
                result[result.count - 1].tokens += word.tokens
            } else { result.append(word) }
        }
        return result.filter { !$0.word.isEmpty && !appended.contains($0.word) && !prepended.contains($0.word) }
    }
}
