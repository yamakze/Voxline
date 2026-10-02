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
            throw ProjectValidationError.invalidCue(id)
        }
        guard text != sourceText else { return }
        let (revision, overflow) = sourceRevision.addingReportingOverflow(1)
        guard !overflow else { throw ProjectValidationError.sourceRevisionOverflow(id) }
        sourceText = text
        sourceRevision = revision
    }

    public var hasCurrentTranslation: Bool {
        if case .succeeded(let text, let revision) = translation {
            return revision == sourceRevision && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }

    public func validate() throws {
        guard startMilliseconds >= 0, endMilliseconds > startMilliseconds, sourceRevision > 0,
              !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectValidationError.invalidCue(id)
        }
        switch translation {
        case .pending: break
        case .succeeded(let text, let revision):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  revision > 0, revision <= sourceRevision else {
                throw ProjectValidationError.invalidTranslation(id)
            }
        case .failed(let reason):
            guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProjectValidationError.invalidTranslation(id)
            }
        }
    }

    public static func validateTimeline(_ cues: [SubtitleCue], within media: MediaIdentity?) throws {
        var identities = Set<UUID>()
        var previousEnd: Int64 = 0
        for cue in cues {
            try cue.validate()
            guard identities.insert(cue.id).inserted else { throw ProjectValidationError.duplicateCue(cue.id) }
            guard cue.startMilliseconds >= previousEnd else {
                throw ProjectValidationError.overlappingOrUnorderedCue(cue.id)
            }
            if let media, cue.endMilliseconds > media.durationMilliseconds {
                throw ProjectValidationError.cueOutsideMedia(cue.id)
            }
            previousEnd = cue.endMilliseconds
        }
    }
}

public enum CueTranslation: Codable, Equatable, Sendable {
    case pending
    case succeeded(text: String, sourceRevision: UInt64)
    case failed(reason: String)
}
