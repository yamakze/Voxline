import Foundation

public struct SubtitleCue: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var startMilliseconds: Int64
    public var endMilliseconds: Int64
    public private(set) var sourceText: String
    public private(set) var sourceRevision: UInt64
    public var translation: CueTranslation

    public init(id: UUID, startMilliseconds: Int64, endMilliseconds: Int64, sourceText: String) throws {
        self.id = id
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.sourceText = sourceText
        sourceRevision = 1
        translation = .pending
        try validate()
    }

    public mutating func replaceSourceText(with text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DomainValidationError.invalidCue(id)
        }
        guard text != sourceText else { return }
        let (revision, overflow) = sourceRevision.addingReportingOverflow(1)
        guard !overflow else { throw DomainValidationError.sourceRevisionOverflow(id) }
        sourceText = text
        sourceRevision = revision
    }

    public var hasTranslation: Bool {
        if case .succeeded(let text, _) = translation {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }

    public func validate() throws {
        guard startMilliseconds >= 0, endMilliseconds > startMilliseconds, sourceRevision > 0,
              !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DomainValidationError.invalidCue(id)
        }
        try translation.validate(cueID: id, sourceRevision: sourceRevision)
    }

    public static func validateTimeline(_ cues: [SubtitleCue], within media: MediaIdentity?) throws {
        var identities = Set<UUID>()
        var previousEnd: Int64 = 0
        for cue in cues {
            try cue.validate()
            guard identities.insert(cue.id).inserted else { throw DomainValidationError.duplicateCue(cue.id) }
            guard cue.startMilliseconds >= previousEnd else {
                throw DomainValidationError.overlappingOrUnorderedCue(cue.id)
            }
            if let media, cue.endMilliseconds > media.durationMilliseconds {
                throw DomainValidationError.cueOutsideMedia(cue.id)
            }
            previousEnd = cue.endMilliseconds
        }
    }

    /// Export/edit boundaries clip a cue ending past the media, preserving its text and start.
    /// A cue starting outside the media, zero duration, duplicate ID or overlap remains an error.
    public static func clampedToMedia(_ cues: [SubtitleCue], media: MediaIdentity?) throws -> [SubtitleCue] {
        guard let media else {
            try validateTimeline(cues, within: nil)
            return cues
        }
        var result = cues
        for index in result.indices {
            let end = result[index].endMilliseconds
            if end > media.durationMilliseconds,
               result[index].startMilliseconds < media.durationMilliseconds {
                result[index].endMilliseconds = media.durationMilliseconds
            }
        }
        try validateTimeline(result, within: media)
        return result
    }
}

public enum CueTranslation: Codable, Equatable, Sendable {
    case pending
    case succeeded(text: String, sourceRevision: UInt64)
    case failed(reason: String)

    func validate(cueID: UUID, sourceRevision: UInt64) throws {
        switch self {
        case .pending: break
        case .succeeded(let text, let revision):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  revision > 0, revision <= sourceRevision else {
                throw DomainValidationError.invalidTranslation(cueID)
            }
        case .failed(let reason):
            guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DomainValidationError.invalidTranslation(cueID)
            }
        }
    }

}
