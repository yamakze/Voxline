import Foundation
import Observation
import VoxlineCore
import VoxlineMedia

/// Shared import draft. Views select a source and supply their actual persistence boundary.
@Observable @MainActor
final class SubtitleImportSession {
    enum Role { case original, translation }
    let item: TaskMediaItem
    let role: Role
    let cuesByID: [UUID: SubtitleCue]
    private(set) var entries: [SubtitleImportEntry] = []
    private(set) var origin: ImportedSubtitleOrigin?
    private(set) var tracks: [EmbeddedSubtitleTrack] = []
    var selectedTrackID: Int32?
    var assignments: [SubtitleTranslationAssignment] = []
    private(set) var isReading = false
    var errorMessage: String?
    private let mediaURL: URL?
    private let reader: SubtitleImportReader
    private let mediaStore: LocalMediaStore

    init(item: TaskMediaItem, role: Role, mediaURL: URL? = nil,
         reader: SubtitleImportReader = .shared, mediaStore: LocalMediaStore = .shared,
         resumingUnmatched: Bool = false) {
        self.item = item; self.role = role; self.mediaURL = mediaURL
        cuesByID = Dictionary(item.cues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.reader = reader; self.mediaStore = mediaStore
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
        clearSelection()
        isReading = true; errorMessage = nil
        defer { isReading = false }
        do {
            let result = try await reader.readFile(url)
            try Task.checkCancellation()
            try accept(result, origin: .file(name: url.lastPathComponent))
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }

    func loadEmbeddedTracks() async {
        clearSelection()
        tracks = []; selectedTrackID = nil
        isReading = true; errorMessage = nil
        defer { isReading = false }
        do {
            let url = try await sourceURL()
            tracks = try await reader.tracks(in: url)
            selectedTrackID = tracks.count == 1 ? tracks[0].id : nil
            if tracks.count == 1 { await readSelectedTrack() }
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }

    func readSelectedTrack() async {
        clearSelection()
        guard let track = tracks.first(where: { $0.id == selectedTrackID }) else { return }
        isReading = true; errorMessage = nil
        defer { isReading = false }
        do {
            let url = try await sourceURL()
            let result = try await reader.readEmbeddedTrack(track.id, in: url)
            try Task.checkCancellation()
            try accept(result, origin: .embedded(trackID: track.id, language: track.language))
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }

    func originalSelection() throws -> SubtitleImportSelection {
        guard let origin, !entries.isEmpty else { throw SubtitleImportError.emptyFile }
        return .init(entries: entries, origin: origin)
    }

    func clearSelection() {
        entries = []; assignments = []; origin = nil
    }

    private func accept(_ result: [SubtitleImportEntry], origin: ImportedSubtitleOrigin) throws {
        guard item.media != nil else { throw TaskValidationError.unassociatedMedia(item.id) }
        if role == .original { _ = try SubtitleCue.clampedToMedia(result.map { try $0.cue() }, media: item.media) }
        entries = result; self.origin = origin
        if role == .translation { assignments = SubtitleTranslationImport.assignments(entries: result, cues: item.cues) }
    }

    private func sourceURL() async throws -> URL {
        if let mediaURL { return mediaURL }
        guard let identity = item.media,
              let resolved = try await mediaStore.resolve(mediaID: item.id, identity: identity) else { throw BurnInError.missingMedia }
        return resolved.url
    }
}
