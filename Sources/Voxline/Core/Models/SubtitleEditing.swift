import Foundation

public extension TaskMediaItem {
    /// Commit an editable timeline without rewriting recognition or translation history.
    mutating func replaceSubtitles(_ replacement: [SubtitleCue], comparedTo original: [SubtitleCue]) throws {
        guard cues == original else { throw CheckpointError.editedCue }
        let validated = try SubtitleCue.clampedToMedia(replacement, media: media)
        cues = validated
        updateProofreadingStatus()
    }

    mutating func setSubtitleTiming(comparedTo original: SubtitleCue, startMilliseconds: Int64, endMilliseconds: Int64) throws {
        guard let index = cues.firstIndex(where: { $0.id == original.id }), cues[index] == original else {
            throw CheckpointError.editedCue
        }
        var replacement = cues
        replacement[index].startMilliseconds = startMilliseconds
        replacement[index].endMilliseconds = endMilliseconds
        try replaceSubtitles(replacement, comparedTo: cues)
    }

    mutating func insertSubtitle(_ cue: SubtitleCue) throws {
        var replacement = cues
        let index = replacement.firstIndex { $0.startMilliseconds >= cue.startMilliseconds } ?? replacement.endIndex
        replacement.insert(cue, at: index)
        try replaceSubtitles(replacement, comparedTo: cues)
    }

    mutating func deleteSubtitles(comparedTo originals: [SubtitleCue]) throws {
        guard !originals.isEmpty, Set(originals.map(\.id)).count == originals.count,
              originals.allSatisfy({ cues.contains($0) }) else { throw CheckpointError.editedCue }
        let ids = Set(originals.map(\.id))
        try replaceSubtitles(cues.filter { !ids.contains($0.id) }, comparedTo: cues)
    }

    mutating func splitSubtitle(comparedTo original: SubtitleCue, atMilliseconds: Int64,
                                firstSourceText: String, secondSourceText: String,
                                firstTranslationText: String, secondTranslationText: String) throws {
        guard let index = cues.firstIndex(where: { $0.id == original.id }), cues[index] == original else {
            throw CheckpointError.editedCue
        }
        guard atMilliseconds > original.startMilliseconds, atMilliseconds < original.endMilliseconds else {
            throw ProjectValidationError.invalidCue(original.id)
        }
        var first = try SubtitleCue(id: UUID(), startMilliseconds: original.startMilliseconds,
            endMilliseconds: atMilliseconds, sourceText: firstSourceText)
        var second = try SubtitleCue(id: UUID(), startMilliseconds: atMilliseconds,
            endMilliseconds: original.endMilliseconds, sourceText: secondSourceText)
        if !firstTranslationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            first.translation = .succeeded(text: firstTranslationText, sourceRevision: first.sourceRevision)
        }
        if !secondTranslationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            second.translation = .succeeded(text: secondTranslationText, sourceRevision: second.sourceRevision)
        }
        var replacement = cues
        replacement.replaceSubrange(index...index, with: [first, second])
        try replaceSubtitles(replacement, comparedTo: cues)
    }

    mutating func mergeSubtitles(comparedTo originals: [SubtitleCue], sourceText: String, translationText: String) throws {
        guard originals.count >= 2 else { throw SubtitleEditingError.nonAdjacentSelection }
        guard let index = cues.firstIndex(where: { $0.id == originals[0].id }) else { throw CheckpointError.editedCue }
        guard index + originals.count <= cues.count,
              Array(cues[index..<(index + originals.count)]).map(\.id) == originals.map(\.id) else {
            throw SubtitleEditingError.nonAdjacentSelection
        }
        guard Array(cues[index..<(index + originals.count)]) == originals else { throw CheckpointError.editedCue }
        var merged = try SubtitleCue(id: UUID(), startMilliseconds: originals[0].startMilliseconds,
            endMilliseconds: originals[originals.count - 1].endMilliseconds, sourceText: sourceText)
        if !translationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            merged.translation = .succeeded(text: translationText, sourceRevision: merged.sourceRevision)
        }
        var replacement = cues
        replacement.replaceSubrange(index..<(index + originals.count), with: [merged])
        try replaceSubtitles(replacement, comparedTo: cues)
    }
}

public enum SubtitleEditingError: Error, LocalizedError {
    case nonAdjacentSelection
    public var errorDescription: String? {
        String(localized: "请选择相邻字幕合并。", bundle: voxlineLocalizationBundle)
    }
}
