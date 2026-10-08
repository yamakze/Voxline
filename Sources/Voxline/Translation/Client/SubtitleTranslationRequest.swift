import Foundation
import VoxlineCore

public struct TranslationContextCue: Codable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public init(cue: SubtitleCue) { id = cue.id; text = cue.sourceText }
}

public struct SubtitleTranslationRequest: Sendable {
    public let inputs: [TranslationBatchInput]
    public let contextBefore: [TranslationContextCue]
    public let contextAfter: [TranslationContextCue]

    public init(inputs: [TranslationBatchInput], cues: [SubtitleCue]) throws {
        let positions = Dictionary(cues.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        guard positions.count == cues.count else { throw SubtitleTranslationError.invalidRequest }
        try self.init(inputs: inputs, cues: cues, positions: positions)
    }

    fileprivate init(inputs: [TranslationBatchInput], cues: [SubtitleCue], positions: [UUID: Int]) throws {
        guard !inputs.isEmpty, Set(inputs.map(\.cueID)).count == inputs.count,
              inputs.allSatisfy({ input in positions[input.cueID].map { input.matches(cues[$0]) } == true }),
              let first = positions[inputs[0].cueID], let last = positions[inputs[inputs.count - 1].cueID], first <= last else {
            throw SubtitleTranslationError.invalidRequest
        }
        self.inputs = inputs
        contextBefore = cues[max(0, first - 2)..<first].map(TranslationContextCue.init)
        contextAfter = cues[(last + 1)..<min(cues.count, last + 3)].map(TranslationContextCue.init)
    }

    func payload(targetLanguage: String) throws -> Data {
        struct Input: Encodable { let id: UUID; let text: String }
        struct Payload: Encodable {
            let targetLanguage: String
            let contextBefore: [TranslationContextCue]
            let subtitles: [Input]
            let contextAfter: [TranslationContextCue]
        }
        return try JSONEncoder().encode(Payload(targetLanguage: targetLanguage, contextBefore: contextBefore,
            subtitles: inputs.map { .init(id: $0.cueID, text: $0.sourceText) }, contextAfter: contextAfter))
    }
}

public enum SubtitleTranslationBatchPlanner {
    public static let maximumPayloadBytes = 12_000

    /// Bounded UTF-8 input, including two neighboring cues on either side. This is not a token estimate.
    public static func batches(cues: [SubtitleCue], pendingIDs: [UUID], targetLanguage: String, batchSize: Int = TranslationSettings.defaultBatchSize) throws -> [[UUID]] {
        guard batchSize > 0 else { throw ProjectValidationError.invalidTranslationBatchSize }
        guard Set(pendingIDs).count == pendingIDs.count,
              Set(pendingIDs).isSubset(of: Set(cues.map(\.id))) else { throw SubtitleTranslationError.invalidRequest }
        let positions = Dictionary(cues.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        guard positions.count == cues.count else { throw SubtitleTranslationError.invalidRequest }
        let pending = Set(pendingIDs)
        var result: [[UUID]] = []
        var current: [SubtitleCue] = []
        for cue in cues where pending.contains(cue.id) {
            let candidate = current + [cue]
            // Use the same serialized envelope as the client so context counts toward the limit.
            let request = try SubtitleTranslationRequest(inputs: candidate.map(TranslationBatchInput.init), cues: cues, positions: positions)
            let bytes = try request.payload(targetLanguage: targetLanguage).count
            if candidate.count > batchSize || bytes > maximumPayloadBytes {
                guard !current.isEmpty else { throw SubtitleTranslationError.requestTooLarge }
                result.append(current.map(\.id))
                current = [cue]
                let single = try SubtitleTranslationRequest(inputs: current.map(TranslationBatchInput.init), cues: cues, positions: positions)
                guard try single.payload(targetLanguage: targetLanguage).count <= maximumPayloadBytes else {
                    throw SubtitleTranslationError.requestTooLarge
                }
            } else { current = candidate }
        }
        if !current.isEmpty { result.append(current.map(\.id)) }
        return result
    }
}
