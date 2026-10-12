import Foundation

public struct SubtitleTranslationAssignment: Identifiable, Equatable, Sendable {
    public var id: UUID { entry.id }
    public let entry: SubtitleImportEntry
    public let candidateCueIDs: [UUID]
    public var cueID: UUID?
}

public enum SubtitleTranslationImport {
    /// Match by temporal intersection. Ties and many-to-one suggestions require user selection.
    public static func assignments(entries: [SubtitleImportEntry], cues: [SubtitleCue]) -> [SubtitleTranslationAssignment] {
        var prefixEnds: [Int64] = []
        var lastEnd: Int64 = 0
        for cue in cues { lastEnd = max(lastEnd, cue.endMilliseconds); prefixEnds.append(lastEnd) }
        var result = entries.map { entry -> SubtitleTranslationAssignment in
            var lower = 0, upper = cues.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if prefixEnds[middle] <= entry.startMilliseconds { lower = middle + 1 } else { upper = middle }
            }
            var candidates: [(id: UUID, score: Double)] = []
            var index = lower
            while index < cues.count, cues[index].startMilliseconds < entry.endMilliseconds {
                let cue = cues[index]
                let overlap = min(entry.endMilliseconds, cue.endMilliseconds) - max(entry.startMilliseconds, cue.startMilliseconds)
                if overlap > 0 {
                    let span = max(entry.endMilliseconds, cue.endMilliseconds) - min(entry.startMilliseconds, cue.startMilliseconds)
                    candidates.append((cue.id, Double(overlap) / Double(span)))
                }
                index += 1
            }
            candidates.sort { $0.score > $1.score }
            let uniqueBest = candidates.count == 1 || (candidates.count > 1 && candidates[0].score > candidates[1].score)
            return .init(entry: entry, candidateCueIDs: candidates.map(\.id), cueID: uniqueBest ? candidates.first?.id : nil)
        }
        var counts: [UUID: Int] = [:]
        for assignment in result { if let id = assignment.cueID { counts[id, default: 0] += 1 } }
        for index in result.indices {
            if let id = result[index].cueID, counts[id] != 1 { result[index].cueID = nil }
        }
        return result
    }
}


public extension TaskMediaItem {
    mutating func importTranslations(_ assignments: [SubtitleTranslationAssignment], comparedTo original: [SubtitleCue],
                                     replacingExisting: Bool = false) throws {
        guard cues == original else { throw CheckpointError.editedCue }
        guard !cues.isEmpty else { throw SubtitleImportError.missingSource }
        guard !isActivelyProcessing else { throw CheckpointError.workRunning }
        var positions: [UUID: Int] = [:]
        for (index, cue) in cues.enumerated() {
            guard positions.updateValue(index, forKey: cue.id) == nil else { throw DomainValidationError.duplicateCue(cue.id) }
        }
        var grouped: [UUID: [SubtitleImportEntry]] = [:]
        let incomingIDs = Set(assignments.map(\.entry.id))
        var unmatched = (unmatchedTranslationEntries ?? []).filter { !incomingIDs.contains($0.id) }
        for assignment in assignments {
            guard let id = assignment.cueID else { unmatched.append(assignment.entry); continue }
            guard let position = positions[id] else { throw CheckpointError.editedCue }
            if cues[position].hasTranslation, !replacingExisting { throw SubtitleImportError.replacementRequired }
            guard !assignment.entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SubtitleImportError.emptyFile }
            grouped[id, default: []].append(assignment.entry)
        }
        var updated = self
        for (id, entries) in grouped {
            let index = positions[id]!
            updated.cues[index].translation = .succeeded(text: entries.map(\.text).joined(separator: "\n"), sourceRevision: updated.cues[index].sourceRevision)
        }
        // Unassigned text remains in the document and can be explicitly matched after reopening.
        updated.unmatchedTranslationEntries = unmatched.isEmpty ? nil : unmatched
        updated.updateProofreadingStatus()
        try updated.validate()
        self = updated
    }

    var isActivelyProcessing: Bool { if case .running = status { true } else { false } }
}
