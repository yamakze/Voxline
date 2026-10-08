#if os(iOS)
import SwiftUI
import UIKit
import VoxlineCore

@MainActor
enum IOSExportHelper {
    static func prepareSRT(for item: TaskMediaItem, kind: SRTOutputKind) throws -> URL {
        let content = try SubtitleExporter.generateSRT(cues: item.cues, kind: kind, media: item.media)
        let fileName = SubtitleExporter.suggestedFileName(mediaTitle: item.media?.fileName ?? item.title, kind: kind)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try content.write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    static func prepareTaskArchive(for task: ProcessingTask) throws -> URL {
        let data = try TaskDocumentCodec.encode(task)
        let safeTitle = task.title.replacingOccurrences(of: "/", with: "-")
        let fileName = "\(safeTitle.isEmpty ? String(localized: "任务", bundle: appLocalizationBundle) : safeTitle).voxline"
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try data.write(to: destination, options: .atomic)
        return destination
    }
}

struct ShareActivitySheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
