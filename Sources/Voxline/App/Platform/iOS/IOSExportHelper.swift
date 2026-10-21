#if os(iOS)
import SwiftUI
import UIKit
import VoxlineCore

enum IOSExportHelper {
    @concurrent
    static func prepareSRT(for item: TaskMediaItem, kind: SRTOutputKind) async throws -> TemporaryExportFile {
        let fileName = SubtitleExporter.suggestedFileName(mediaTitle: item.media?.fileName ?? item.title, kind: kind)
        let file = try TemporaryExportFile(fileName: fileName)
        try await SubtitleExporter.export(cues: item.cues, kind: kind, to: file.url, media: item.media)
        try Task.checkCancellation()
        return file
    }

    @concurrent
    static func prepareTaskArchive(for task: ProcessingTask) async throws -> TemporaryExportFile {
        try Task.checkCancellation()
        let data = try TaskDocumentCodec.encode(task)
        let safeTitle = task.title.replacingOccurrences(of: "/", with: "-")
        let fileName = "\(safeTitle.isEmpty ? String(localized: "任务", bundle: appLocalizationBundle) : safeTitle).voxline"
        let file = try TemporaryExportFile(fileName: fileName)
        try Task.checkCancellation()
        try data.write(to: file.url, options: .atomic)
        try Task.checkCancellation()
        return file
    }
}

struct ShareActivitySheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    var retainedFile: TemporaryExportFile? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.completionWithItemsHandler = { [retainedFile] _, _, _, _ in
            withExtendedLifetime(retainedFile) { }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
