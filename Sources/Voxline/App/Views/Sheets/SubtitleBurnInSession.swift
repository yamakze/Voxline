import CoreGraphics
import Foundation
import Observation
import VoxlineCore
import VoxlineMedia

/// The same frozen subtitle composition serves both native preview and export sheets.
@Observable @MainActor
final class SubtitleBurnInSession {
    let item: TaskMediaItem
    var options: BurnInOptions
    private(set) var plan: SubtitleBurnInPlan?
    var previewImage: CGImage?
    var previewTime: Int64
    var fileName: String
    var errorMessage: String?
    var exportedURL: URL?
    private(set) var temporaryExport: TemporaryExportFile?
    var requiresOverwriteConfirmation = false
    private(set) var isPreparing = false
    private(set) var isExporting = false
    private(set) var progress: Double = 0
    @ObservationIgnored private var operation: Task<Void, Never>?

    init(item: TaskMediaItem) {
        self.item = item
        var options = BurnInOptions()
        options.kind = item.cues.allSatisfy(\.hasTranslation) ? .bilingual : .source
        self.options = options
        previewTime = item.cues.first?.startMilliseconds ?? 0
        fileName = "\(((item.media?.fileName ?? item.title) as NSString).deletingPathExtension).subtitled.mp4"
    }

    func cancel() { operation?.cancel() }
    func close() { operation?.cancel(); plan?.releaseAccess(); temporaryExport = nil }

    func invalidatePreview() {
        plan?.releaseAccess()
        plan = nil
        previewImage = nil
        exportedURL = nil
        temporaryExport = nil
        errorMessage = nil
    }

    func refreshPreview() {
        isPreparing = true
        errorMessage = nil
        exportedURL = nil
        temporaryExport = nil
        operation = Task { @MainActor in
            defer { isPreparing = false; operation = nil }
            do {
                if plan == nil { plan = try await SubtitleBurnInExporter.composition(for: item, options: options) }
                guard let plan else { throw BurnInError.invalidGeometry }
                previewImage = try await plan.preview(atMilliseconds: previewTime, maximumSize: CGSize(width: 1280, height: 720))
            } catch {
                previewImage = nil
                errorMessage = error is CancellationError ? String(localized: "预览已取消。", bundle: appLocalizationBundle) : error.localizedDescription
            }
        }
    }

    func startExport(to destination: URL, accessDirectory directory: URL, allowOverwrite: Bool,
                     temporaryFile: TemporaryExportFile? = nil) {
        isExporting = true
        progress = 0
        errorMessage = nil
        exportedURL = nil
        temporaryExport = nil
        requiresOverwriteConfirmation = false
        operation = Task { @MainActor in
            let access = directory.startAccessingSecurityScopedResource()
            defer {
                if access { directory.stopAccessingSecurityScopedResource() }
                isExporting = false
                operation = nil
            }
            do {
                if plan == nil { plan = try await SubtitleBurnInExporter.composition(for: item, options: options) }
                guard let plan else { throw BurnInError.invalidGeometry }
                try await SubtitleBurnInExporter.export(plan, to: destination, allowOverwrite: allowOverwrite) { self.progress = $0 }
                try Task.checkCancellation()
                temporaryExport = temporaryFile
                exportedURL = destination
            } catch BurnInError.fileAlreadyExists {
                if allowOverwrite { errorMessage = BurnInError.fileAlreadyExists.localizedDescription }
                else { requiresOverwriteConfirmation = true }
            } catch {
                errorMessage = error is CancellationError ? String(localized: "烧录已取消，未发布输出文件。", bundle: appLocalizationBundle) : error.localizedDescription
            }
        }
    }
}
