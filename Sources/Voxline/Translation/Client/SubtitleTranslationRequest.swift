import Foundation
import VoxlineCore

public struct TranslationContextCue: Codable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public init(cue: SubtitleCue) { id = cue.id; text = cue.sourceText }
    fileprivate init(input: TranslationBatchInput) { id = input.cueID; text = input.sourceText }
}

public struct SubtitleTranslationRequest: Sendable {
    public let inputs: [TranslationBatchInput]
    public let contextBefore: [TranslationContextCue]
    public let contextAfter: [TranslationContextCue]

    public init(inputs: [TranslationBatchInput], cues: [SubtitleCue]) throws {
        let positions = Dictionary(cues.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        guard positions.count == cues.count else { throw SubtitleTranslationError.invalidRequest }
        try self.init(inputs: inputs, cues: cues, cuePosition: { positions[$0] })
    }

    /// The executor can reuse its operation-local index while checking the current subtitle snapshot.
    public init(inputs: [TranslationBatchInput], cues: [SubtitleCue], cuePosition: (UUID) -> Int?) throws {
        guard !inputs.isEmpty, Set(inputs.map(\.cueID)).count == inputs.count,
              inputs.allSatisfy({ input in
                  cuePosition(input.cueID).map { cues.indices.contains($0) && input.matches(cues[$0]) } == true
              }),
              let first = cuePosition(inputs[0].cueID), let last = cuePosition(inputs[inputs.count - 1].cueID), first <= last else {
            throw SubtitleTranslationError.invalidRequest
        }
        self.inputs = inputs
        contextBefore = cues[max(0, first - 2)..<first].map(TranslationContextCue.init)
        contextAfter = cues[(last + 1)..<min(cues.count, last + 3)].map(TranslationContextCue.init)
    }

    fileprivate struct Payload: Encodable {
        let targetLanguage: String
        let contextBefore: [TranslationContextCue]
        let subtitles: [TranslationContextCue]
        let contextAfter: [TranslationContextCue]
    }

    func payload(targetLanguage: String) throws -> Data {
        return try JSONEncoder().encode(Payload(targetLanguage: targetLanguage, contextBefore: contextBefore,
            subtitles: inputs.map(TranslationContextCue.init), contextAfter: contextAfter))
    }
}

public enum SubtitleTranslationBatchPlanner {
    public static let maximumPayloadBytes = 12_000

    /// Bounded UTF-8 input, including two neighboring cues on either side. This is not a token estimate.
    public static func batches(cues: [SubtitleCue], pendingIDs: [UUID], targetLanguage: String, batchSize: Int = TranslationSettings.defaultBatchSize) throws -> [[UUID]] {
        guard batchSize > 0 else { throw ProjectValidationError.invalidTranslationBatchSize }
        let cueIDs = Set(cues.map(\.id))
        let pending = Set(pendingIDs)
        guard cueIDs.count == cues.count, pending.count == pendingIDs.count,
              pending.isSubset(of: cueIDs) else { throw SubtitleTranslationError.invalidRequest }
        guard !pending.isEmpty else { return [] }
        let encoder = JSONEncoder()
        let envelopeBytes = try encoder.encode(SubtitleTranslationRequest.Payload(targetLanguage: targetLanguage,
            contextBefore: [], subtitles: [], contextAfter: [])).count
        // Each cue object is serialized once. The three arrays add only their objects and commas
        // to the same empty envelope used by the HTTP client; escaped UTF-8 is counted exactly.
        var encodedBytes = [Int?](repeating: nil, count: cues.count)
        func cueBytes(at position: Int) throws -> Int {
            if let bytes = encodedBytes[position] { return bytes }
            let bytes = try encoder.encode(TranslationContextCue(cue: cues[position])).count
            encodedBytes[position] = bytes
            return bytes
        }
        func contextBytes(_ range: Range<Int>) throws -> Int {
            var bytes = max(0, range.count - 1)
            for position in range { bytes += try cueBytes(at: position) }
            return bytes
        }
        var result: [[UUID]] = []
        var current: [UUID] = []
        var first = 0
        var subtitleBytes = 0
        for (position, cue) in cues.enumerated() where pending.contains(cue.id) {
            if current.isEmpty { first = position }
            let cueBytes = try cueBytes(at: position)
            let beforeBytes = try contextBytes(max(0, first - 2)..<first)
            let afterBytes = try contextBytes((position + 1)..<min(cues.count, position + 3))
            let bytes = envelopeBytes + beforeBytes + subtitleBytes + cueBytes + current.count + afterBytes
            if current.count == batchSize || bytes > maximumPayloadBytes {
                guard !current.isEmpty else { throw SubtitleTranslationError.requestTooLarge }
                result.append(current)
                current = []
                first = position
                subtitleBytes = 0
                guard try envelopeBytes + contextBytes(max(0, position - 2)..<position) + cueBytes + afterBytes <= maximumPayloadBytes else {
                    throw SubtitleTranslationError.requestTooLarge
                }
            }
            current.append(cue.id)
            subtitleBytes += cueBytes
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
