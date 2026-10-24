import Foundation
import Observation
import VoxlineCore
import VoxlineMedia

/// Shared export operation; platform sheets choose a destination and present the result.
@Observable @MainActor
final class SubtitleEmbeddingSession {
    let item: TaskMediaItem
    let missingTranslationCount: Int
    private let parameters: TaskParameters?
    var selectedKind: SRTOutputKind
    var fileName: String
    var errorMessage: String?
    var exportedURL: URL?
    private(set) var isExporting = false
    private(set) var progress: Double = 0
    @ObservationIgnored private var exportTask: Task<Void, Never>?

    init(item: TaskMediaItem, task: ProcessingTask?) {
        self.item = item
        missingTranslationCount = item.cues.reduce(0) { $0 + ($1.hasTranslation ? 0 : 1) }
        parameters = task?.parameters
        selectedKind = missingTranslationCount == 0 ? .bilingual : .source
        let base = ((item.media?.fileName ?? item.title) as NSString).deletingPathExtension
        fileName = "\(base).embedded.mp4"
    }

    var languageTag: String {
        let code = selectedKind == .source ? parameters?.transcription.languageCode : parameters?.translation?.targetLanguage
        return code.flatMap { $0.isEmpty ? nil : $0 } ?? "und"
    }

    func cancel() { exportTask?.cancel() }

    func startExport(to destination: URL, accessDirectory directory: URL, allowOverwrite: Bool) {
        errorMessage = nil
        exportedURL = nil
        isExporting = true
        progress = 0
        let kind = selectedKind
        let tag = languageTag
        let accessing = directory.startAccessingSecurityScopedResource()
        exportTask = Task { @MainActor in
            defer {
                if accessing { directory.stopAccessingSecurityScopedResource() }
                isExporting = false
                exportTask = nil
            }
            do {
                try await SubtitleEmbeddingExporter.export(item: item, kind: kind, to: destination,
                    languageTag: tag, allowOverwrite: allowOverwrite, progress: { self.progress = $0 })
                exportedURL = destination
            } catch is CancellationError {
                errorMessage = String(localized: "导出已取消。", bundle: appLocalizationBundle)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
