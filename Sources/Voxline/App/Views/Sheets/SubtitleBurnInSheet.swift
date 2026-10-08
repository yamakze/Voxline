#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore
import VoxlineMedia

struct SubtitleBurnInSheet: View {
    @State private var item: TaskMediaItem
    @Environment(\.dismiss) private var dismiss
    @State private var options = BurnInOptions()
    @State private var plan: SubtitleBurnInPlan?
    @State private var previewImage: NSImage?
    @State private var previewTime: Int64 = 0
    @State private var fileName: String
    @State private var targetDirectory: URL?
    @State private var showDirectoryPicker = false
    @State private var showOverwriteAlert = false
    @State private var errorMessage: String?
    @State private var exportedURL: URL?
    @State private var isPreparing = false
    @State private var isExporting = false
    @State private var progress: Double = 0
    @State private var operation: Task<Void, Never>?

    init(item: TaskMediaItem) {
        _item = State(initialValue: item)
        _fileName = State(initialValue: "\(((item.media?.fileName ?? item.title) as NSString).deletingPathExtension).subtitled.mp4")
        _previewTime = State(initialValue: item.cues.first?.startMilliseconds ?? 0)
        _options = State(initialValue: {
            var options = BurnInOptions()
            options.kind = item.cues.allSatisfy(\.hasCurrentTranslation) ? .bilingual : .source
            return options
        }())
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(String(localized: "烧录字幕视频", bundle: appLocalizationBundle)).font(.headline)
                Spacer()
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 10) {
                    if let previewImage {
                        Image(nsImage: previewImage).resizable().scaledToFit()
                            .frame(width: 400, height: 240).background(.black)
                    } else {
                        ContentUnavailableView(String(localized: "输出预览", bundle: appLocalizationBundle), systemImage: "film",
                            description: Text(String(localized: "选择字幕和输出设置，生成实际合成画面。", bundle: appLocalizationBundle)))
                            .frame(width: 400, height: 240)
                    }
                    Picker(String(localized: "预览字幕", bundle: appLocalizationBundle), selection: $previewTime) {
                        ForEach(item.cues) { cue in
                            Text("\(SubtitleExporter.formatSRTTimestamp(milliseconds: cue.startMilliseconds)) · \(cue.sourceText.prefix(30))")
                                .tag(cue.startMilliseconds)
                        }
                    }
                    .disabled(isPreparing || isExporting)
                    Button(isPreparing ? String(localized: "正在生成预览…", bundle: appLocalizationBundle) : String(localized: "更新预览", bundle: appLocalizationBundle)) { refreshPreview() }
                        .disabled(isPreparing || isExporting)
                    if let plan {
                        Text("\(Int(plan.renderSize.width)) × \(Int(plan.renderSize.height)) · \(1 / plan.videoComposition.frameDuration.seconds, specifier: "%.2f") fps")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Form {
                    Picker(String(localized: "字幕", bundle: appLocalizationBundle), selection: $options.kind) {
                        Text(String(localized: "原文", bundle: appLocalizationBundle)).tag(SRTOutputKind.source)
                        Text(String(localized: "译文", bundle: appLocalizationBundle)).tag(SRTOutputKind.translation)
                        Text(String(localized: "双语", bundle: appLocalizationBundle)).tag(SRTOutputKind.bilingual)
                    }
                    Picker(String(localized: "编码", bundle: appLocalizationBundle), selection: $options.codec) {
                        ForEach(BurnInCodec.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker(String(localized: "质量", bundle: appLocalizationBundle), selection: $options.quality) {
                        ForEach(BurnInQuality.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Stepper(String(localized: "字号：\(Int(options.fontSize))（1080p 基准）", bundle: appLocalizationBundle), value: $options.fontSize, in: 16...72, step: 2)
                    Text(String(localized: "底部居中 · 白字深色背景 · SDR\n使用本次校对字幕与所选音轨，输出新的 MP4。", bundle: appLocalizationBundle))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(isPreparing || isExporting)
                .frame(width: 340)
            }
            TextField(String(localized: "输出文件名", bundle: appLocalizationBundle), text: $fileName).textFieldStyle(.roundedBorder).disabled(isExporting)
            HStack {
                Text(targetDirectory?.path ?? String(localized: "请选择保存目录", bundle: appLocalizationBundle)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(String(localized: "选择目录…", bundle: appLocalizationBundle)) { showDirectoryPicker = true }.disabled(isExporting)
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            if isExporting { ProgressView(value: progress) }
            if let exportedURL {
                Label(String(localized: "已导出：\(exportedURL.lastPathComponent)", bundle: appLocalizationBundle), systemImage: "checkmark.circle.fill")
                Button(String(localized: "在 Finder 中显示", bundle: appLocalizationBundle)) { NSWorkspace.shared.activateFileViewerSelecting([exportedURL]) }
            }
            HStack {
                if isPreparing || isExporting {
                    Button(String(localized: "停止", bundle: appLocalizationBundle)) { operation?.cancel() }
                    Text(isExporting ? String(localized: "正在烧录 \(Int(progress * 100))%", bundle: appLocalizationBundle) : String(localized: "正在准备画面…", bundle: appLocalizationBundle)).font(.caption)
                }
                Spacer()
                Button(String(localized: "取消", bundle: appLocalizationBundle)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isPreparing || isExporting)
                Button(String(localized: "烧录并导出", bundle: appLocalizationBundle)) { startExport(allowOverwrite: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(plan == nil || previewImage == nil || targetDirectory == nil || isPreparing || isExporting)
            }
        }
        .padding(24).frame(width: 820)
        .onChange(of: options) { _, _ in invalidatePreview() }
        .onChange(of: previewTime) { _, _ in previewImage = nil }
        .onChange(of: fileName) { _, _ in exportedURL = nil }
        .onDisappear { operation?.cancel(); plan?.releaseAccess() }
        .fileImporter(isPresented: $showDirectoryPicker, allowedContentTypes: [.folder]) { result in
            do { targetDirectory = try result.get(); errorMessage = nil; exportedURL = nil }
            catch { errorMessage = error.localizedDescription }
        }
        .alert(String(localized: "输出文件已存在", bundle: appLocalizationBundle), isPresented: $showOverwriteAlert) {
            Button(String(localized: "取消", bundle: appLocalizationBundle), role: .cancel) {}
            Button(String(localized: "覆盖并导出", bundle: appLocalizationBundle), role: .destructive) { startExport(allowOverwrite: true) }
        } message: { Text(String(localized: "是否覆盖“\(fileName)”？原视频始终保留。", bundle: appLocalizationBundle)) }
    }

    private func invalidatePreview() {
        plan?.releaseAccess()
        plan = nil
        previewImage = nil
        exportedURL = nil
        errorMessage = nil
    }

    private func refreshPreview() {
        isPreparing = true
        errorMessage = nil
        exportedURL = nil
        operation = Task { @MainActor in
            defer { isPreparing = false; operation = nil }
            do {
                if plan == nil { plan = try await SubtitleBurnInExporter.composition(for: item, options: options) }
                guard let plan else { throw BurnInError.invalidGeometry }
                let image = try await plan.preview(atMilliseconds: previewTime)
                previewImage = NSImage(cgImage: image, size: .zero)
            } catch {
                previewImage = nil
                errorMessage = error is CancellationError ? String(localized: "预览已取消。", bundle: appLocalizationBundle) : error.localizedDescription
            }
        }
    }

    private func startExport(allowOverwrite: Bool) {
        guard let directory = targetDirectory, let plan else { return }
        isExporting = true
        progress = 0
        errorMessage = nil
        exportedURL = nil
        operation = Task { @MainActor in
            let access = directory.startAccessingSecurityScopedResource()
            defer {
                if access { directory.stopAccessingSecurityScopedResource() }
                isExporting = false
                operation = nil
            }
            do {
                guard !fileName.contains("/"), !fileName.contains("\\") else { throw BurnInError.invalidFileName }
                let destination = directory.appendingPathComponent(fileName)
                try await SubtitleBurnInExporter.export(plan, to: destination, allowOverwrite: allowOverwrite) { progress = $0 }
                exportedURL = destination
            } catch BurnInError.fileAlreadyExists { showOverwriteAlert = true }
            catch { errorMessage = error is CancellationError ? String(localized: "烧录已取消，未发布输出文件。", bundle: appLocalizationBundle) : error.localizedDescription }
        }
    }
}

#endif
