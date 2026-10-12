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
    var assignments: [SubtitleTranslationAssignment] = []
    private(set) var isReading = false
    var errorMessage: String?
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
    }

    var matchedCount: Int { assignments.filter { $0.cueID != nil }.count }
    var replacesExisting: Bool {
        if role == .original { return !item.cues.isEmpty }
        let ids = Set(assignments.compactMap(\.cueID))
        return item.cues.contains { ids.contains($0.id) && $0.hasTranslation }
    }

    func readFile(_ url: URL) async {
        entries = []; assignments = []; origin = nil
        isReading = true; errorMessage = nil
        defer { isReading = false }
        do {
            let result = try await reader.readFile(url)
            try Task.checkCancellation()
            guard item.media != nil else { throw TaskValidationError.unassociatedMedia(item.id) }
            if role == .original { _ = try SubtitleCue.clampedToMedia(result.map { try $0.cue() }, media: item.media) }
            entries = result; origin = .file(name: url.lastPathComponent)
            if role == .translation { assignments = SubtitleTranslationImport.assignments(entries: result, cues: item.cues) }
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }

    func originalSelection() throws -> SubtitleImportSelection {
        guard let origin, !entries.isEmpty else { throw SubtitleImportError.emptyFile }
        return .init(entries: entries, origin: origin)
    }

}
