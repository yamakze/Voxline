import Foundation
import Observation
import VoxlineCore
import VoxlineMedia

/// Shared external-subtitle draft; platform views supply the persistence boundary.
@Observable @MainActor
final class SubtitleImportSession {
    enum Role { case original, translation }
    let item: TaskMediaItem
    let role: Role
    let cuesByID: [UUID: SubtitleCue]
    private(set) var entries: [SubtitleImportEntry] = []
    private(set) var origin: ImportedSubtitleOrigin?
    var assignments: [SubtitleTranslationAssignment] = [] {
        didSet { updateAssignmentCounts() }
    }
    private(set) var cueAssignmentCounts: [UUID: Int] = [:]
    private(set) var matchedCount = 0
    private(set) var isReading = false
    var errorMessage: String?
    @ObservationIgnored private var readingGeneration = UUID()
    private let reader: SubtitleImportReader

    init(item: TaskMediaItem, role: Role, reader: SubtitleImportReader = .shared,
         resumingUnmatched: Bool = false) {
        self.item = item; self.role = role
        cuesByID = Dictionary(item.cues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.reader = reader
        if resumingUnmatched {
            entries = item.unmatchedTranslationEntries ?? []
            assignments = SubtitleTranslationImport.assignments(entries: entries, cues: item.cues)
        }
        updateAssignmentCounts()
    }

    private func updateAssignmentCounts() {
        var counts: [UUID: Int] = [:]
        for assignment in assignments {
            if let id = assignment.cueID { counts[id, default: 0] += 1 }
        }
        cueAssignmentCounts = counts
        matchedCount = counts.values.reduce(0, +)
    }

    func readFile(_ url: URL) async {
        let requestID = UUID()
        readingGeneration = requestID
        entries = []; assignments = []; origin = nil
        isReading = true; errorMessage = nil
        defer { if readingGeneration == requestID { isReading = false } }
        do {
            let result = try await reader.readFile(url)
            try Task.checkCancellation()
            guard readingGeneration == requestID else { return }
            guard item.media != nil else { throw TaskValidationError.unassociatedMedia(item.id) }
            if role == .original {
                let bounded = try SubtitleCue.clampedToMedia(result.map { try $0.cue() }, media: item.media)
                entries = bounded.map { .init(id: $0.id, startMilliseconds: $0.startMilliseconds,
                    endMilliseconds: $0.endMilliseconds, text: $0.sourceText) }
            } else { entries = result }
            origin = .file(name: url.lastPathComponent)
            if role == .translation { assignments = SubtitleTranslationImport.assignments(entries: result, cues: item.cues) }
        } catch is CancellationError { }
        catch { if readingGeneration == requestID { errorMessage = error.localizedDescription } }
    }

    func originalSelection() throws -> SubtitleImportSelection {
        guard let origin, !entries.isEmpty else { throw SubtitleImportError.emptyFile }
        return .init(entries: entries, origin: origin)
    }

}
