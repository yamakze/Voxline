#if os(iOS)
import SwiftUI
import AVKit
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

/// A presented export keeps one player and its temporary file for the preview's lifetime.
struct IOSExportVideoPreview: View {
    let url: URL
    @State private var retainedFile: TemporaryExportFile?
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    init(url: URL, retainedFile: TemporaryExportFile? = nil) {
        self.url = url
        _retainedFile = State(initialValue: retainedFile)
    }

    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .ignoresSafeArea()
                .navigationTitle(String(localized: "视频预览", bundle: appLocalizationBundle))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "完成", bundle: appLocalizationBundle)) { dismiss() }
                    }
                }
        }
        .task(id: url) {
            player?.pause()
            player = AVPlayer(url: url)
        }
        .onDisappear {
            player?.pause()
            player = nil
            retainedFile = nil
        }
    }
}
#endif
