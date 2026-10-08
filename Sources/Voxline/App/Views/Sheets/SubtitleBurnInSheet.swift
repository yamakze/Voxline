#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore
import VoxlineMedia

struct SubtitleBurnInSheet: View {
    @State private var session: SubtitleBurnInSession
    private var item: TaskMediaItem { session.item }
    @Environment(\.dismiss) private var dismiss
    @State private var targetDirectory: URL?
    @State private var showDirectoryPicker = false

    init(item: TaskMediaItem) {
        _session = State(initialValue: SubtitleBurnInSession(item: item))
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(String(localized: "烧录字幕视频", bundle: appLocalizationBundle)).font(.headline)
                Spacer()
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 10) {
                    if let previewImage = session.previewImage {
                        Image(nsImage: NSImage(cgImage: previewImage, size: .zero)).resizable().scaledToFit()
                            .frame(width: 400, height: 240).background(.black)
                    } else {
                        ContentUnavailableView(String(localized: "输出预览", bundle: appLocalizationBundle), systemImage: "film",
                            description: Text(String(localized: "选择字幕和输出设置，生成实际合成画面。", bundle: appLocalizationBundle)))
                            .frame(width: 400, height: 240)
                    }
                    Picker(String(localized: "预览字幕", bundle: appLocalizationBundle), selection: $session.previewTime) {
                        ForEach(item.cues) { cue in
                            Text("\(SubtitleExporter.formatSRTTimestamp(milliseconds: cue.startMilliseconds)) · \(cue.sourceText.prefix(30))")
                                .tag(cue.startMilliseconds)
                        }
                    }
                    .disabled(session.isPreparing || session.isExporting)
                    Button(session.isPreparing ? String(localized: "正在生成预览…", bundle: appLocalizationBundle) : String(localized: "更新预览", bundle: appLocalizationBundle)) { session.refreshPreview() }
                        .disabled(session.isPreparing || session.isExporting)
                    if let plan = session.plan {
                        Text("\(Int(plan.renderSize.width)) × \(Int(plan.renderSize.height)) · \(1 / plan.videoComposition.frameDuration.seconds, specifier: "%.2f") fps")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Form {
                    Picker(String(localized: "字幕", bundle: appLocalizationBundle), selection: $session.options.kind) {
                        Text(String(localized: "原文", bundle: appLocalizationBundle)).tag(SRTOutputKind.source)
                        Text(String(localized: "译文", bundle: appLocalizationBundle)).tag(SRTOutputKind.translation)
                        Text(String(localized: "双语", bundle: appLocalizationBundle)).tag(SRTOutputKind.bilingual)
                    }
                    Picker(String(localized: "编码", bundle: appLocalizationBundle), selection: $session.options.codec) {
                        ForEach(BurnInCodec.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker(String(localized: "质量", bundle: appLocalizationBundle), selection: $session.options.quality) {
                        ForEach(BurnInQuality.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Stepper(String(localized: "字号：\(Int(session.options.fontSize))（1080p 基准）", bundle: appLocalizationBundle), value: $session.options.fontSize, in: 16...72, step: 2)
                    Text(String(localized: "底部居中 · 白字深色背景 · SDR\n使用本次校对字幕与所选音轨，输出新的 MP4。", bundle: appLocalizationBundle))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(session.isPreparing || session.isExporting)
                .frame(width: 340)
            }
            TextField(String(localized: "输出文件名", bundle: appLocalizationBundle), text: $session.fileName).textFieldStyle(.roundedBorder).disabled(session.isExporting)
            HStack {
                Text(targetDirectory?.path ?? String(localized: "请选择保存目录", bundle: appLocalizationBundle)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(String(localized: "选择目录…", bundle: appLocalizationBundle)) { showDirectoryPicker = true }.disabled(session.isExporting)
            }
            if let errorMessage = session.errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            if session.isExporting { ProgressView(value: session.progress) }
            if let exportedURL = session.exportedURL {
                Label(String(localized: "已导出：\(exportedURL.lastPathComponent)", bundle: appLocalizationBundle), systemImage: "checkmark.circle.fill")
                Button(String(localized: "在 Finder 中显示", bundle: appLocalizationBundle)) { NSWorkspace.shared.activateFileViewerSelecting([exportedURL]) }
            }
            HStack {
                if session.isPreparing || session.isExporting {
                    Button(String(localized: "停止", bundle: appLocalizationBundle)) { session.cancel() }
                    Text(session.isExporting ? String(localized: "正在烧录 \(Int(session.progress * 100))%", bundle: appLocalizationBundle) : String(localized: "正在准备画面…", bundle: appLocalizationBundle)).font(.caption)
                }
                Spacer()
                Button(String(localized: "取消", bundle: appLocalizationBundle)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(session.isPreparing || session.isExporting)
                Button(String(localized: "烧录并导出", bundle: appLocalizationBundle)) { startExport(allowOverwrite: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.plan == nil || session.previewImage == nil || targetDirectory == nil || session.isPreparing || session.isExporting)
            }
        }
        .padding(24).frame(width: 820)
        .onChange(of: session.options) { _, _ in session.invalidatePreview() }
        .onChange(of: session.previewTime) { _, _ in session.previewImage = nil }
        .onChange(of: session.fileName) { _, _ in session.exportedURL = nil }
        .onDisappear { session.close() }
        .fileImporter(isPresented: $showDirectoryPicker, allowedContentTypes: [.folder]) { result in
            do { targetDirectory = try result.get(); session.errorMessage = nil; session.exportedURL = nil }
            catch { session.errorMessage = error.localizedDescription }
        }
        .alert(String(localized: "输出文件已存在", bundle: appLocalizationBundle), isPresented: $session.requiresOverwriteConfirmation) {
            Button(String(localized: "取消", bundle: appLocalizationBundle), role: .cancel) {}
            Button(String(localized: "覆盖并导出", bundle: appLocalizationBundle), role: .destructive) { startExport(allowOverwrite: true) }
        } message: { Text(String(localized: "是否覆盖“\(session.fileName)”？原视频始终保留。", bundle: appLocalizationBundle)) }
    }

    private func startExport(allowOverwrite: Bool) {
        guard let directory = targetDirectory else { return }
        guard !session.fileName.contains("/"), !session.fileName.contains("\\") else {
            session.errorMessage = BurnInError.invalidFileName.localizedDescription
            return
        }
        session.startExport(to: directory.appendingPathComponent(session.fileName), accessDirectory: directory, allowOverwrite: allowOverwrite)
    }

}

#endif
