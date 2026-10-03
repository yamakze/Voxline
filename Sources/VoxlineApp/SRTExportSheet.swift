import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore

public struct SRTExportSheet: View {
    let mediaTitle: String
    let cues: [SubtitleCue]
    let media: MediaIdentity?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedKind: SRTOutputKind
    @State private var fileName: String
    @State private var targetDirectory: URL?
    @State private var errorMessage: String?
    @State private var showDirectoryPicker = false
    @State private var showOverwriteAlert = false
    @State private var exportedURL: URL?

    public init(mediaTitle: String, cues: [SubtitleCue], media: MediaIdentity?, initialKind: SRTOutputKind) {
        self.mediaTitle = mediaTitle
        self.cues = cues
        self.media = media
        _selectedKind = State(initialValue: initialKind)
        _fileName = State(initialValue: SubtitleExporter.suggestedFileName(mediaTitle: mediaTitle, kind: initialKind))
    }

    private var missingTranslationCount: Int { cues.filter { !$0.hasCurrentTranslation }.count }

    public var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("导出 SRT 字幕").font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            VStack(alignment: .leading, spacing: 16) {
                Picker("导出类型", selection: $selectedKind) {
                    Text("原文 SRT").tag(SRTOutputKind.source)
                    Text("译文 SRT").tag(SRTOutputKind.translation)
                    Text("双语 SRT").tag(SRTOutputKind.bilingual)
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedKind) { _, kind in
                    fileName = SubtitleExporter.suggestedFileName(mediaTitle: mediaTitle, kind: kind)
                    exportedURL = nil
                    errorMessage = nil
                }
                if selectedKind != .source && missingTranslationCount > 0 {
                    Label("有 \(missingTranslationCount) 条字幕缺少有效译文。请完成翻译或校对，或选择原文 SRT。", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                TextField("文件名", text: $fileName).textFieldStyle(.roundedBorder)
                    .onChange(of: fileName) { _, _ in exportedURL = nil; errorMessage = nil }
                HStack {
                    Text(targetDirectory?.path ?? "请选择保存目录")
                        .font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("选择目录…") { showDirectoryPicker = true }
                }
                if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red) }
                if let exportedURL {
                    Label("已导出：\(exportedURL.lastPathComponent)", systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.green)
                }
            }
            .padding().liquidGlassSurface()
            HStack {
                Text("\(cues.count) 条字幕 · UTF-8 编码").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("导出") { export(allowOverwrite: false) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(targetDirectory == nil || cues.isEmpty || (selectedKind != .source && missingTranslationCount > 0))
            }
        }
        .padding(24).frame(width: 520)
        .fileImporter(isPresented: $showDirectoryPicker, allowedContentTypes: [.folder]) { result in
            do {
                targetDirectory = try result.get()
                errorMessage = nil
                exportedURL = nil
            } catch { errorMessage = error.localizedDescription }
        }
        .alert("文件已存在", isPresented: $showOverwriteAlert) {
            Button("取消", role: .cancel) {}
            Button("覆盖并导出", role: .destructive) { export(allowOverwrite: true) }
        } message: { Text("目录中已存在名为“\(fileName)”的文件。是否确认覆盖？") }
    }

    private func export(allowOverwrite: Bool) {
        guard let directory = targetDirectory else { return }
        errorMessage = nil
        exportedURL = nil
        let accessing = directory.startAccessingSecurityScopedResource()
        defer { if accessing { directory.stopAccessingSecurityScopedResource() } }
        do {
            try SubtitleExporter.validateFileName(fileName)
            let url = directory.appendingPathComponent(fileName)
            try SubtitleExporter.export(cues: cues, kind: selectedKind, to: url, media: media, allowOverwrite: allowOverwrite)
            exportedURL = url
        } catch SubtitleExportError.fileAlreadyExists { showOverwriteAlert = true }
        catch { errorMessage = error.localizedDescription }
    }
}
