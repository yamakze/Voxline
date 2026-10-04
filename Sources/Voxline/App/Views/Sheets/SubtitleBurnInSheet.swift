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
                Text("烧录字幕视频").font(.headline)
                Spacer()
                Button("完成") { dismiss() }.disabled(isPreparing || isExporting)
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 10) {
                    if let previewImage {
                        Image(nsImage: previewImage).resizable().scaledToFit()
                            .frame(width: 400, height: 240).background(.black)
                    } else {
                        ContentUnavailableView("输出预览", systemImage: "film",
                            description: Text("选择字幕和输出设置，生成实际合成画面。"))
                            .frame(width: 400, height: 240)
                    }
                    Picker("预览字幕", selection: $previewTime) {
                        ForEach(item.cues) { cue in
                            Text("\(SubtitleExporter.formatSRTTimestamp(milliseconds: cue.startMilliseconds)) · \(cue.sourceText.prefix(30))")
                                .tag(cue.startMilliseconds)
                        }
                    }
                    .disabled(isPreparing || isExporting)
                    Button(isPreparing ? "正在生成预览…" : "更新预览") { refreshPreview() }
                        .disabled(isPreparing || isExporting)
                    if let plan {
                        Text("\(Int(plan.renderSize.width)) × \(Int(plan.renderSize.height)) · \(1 / plan.videoComposition.frameDuration.seconds, specifier: "%.2f") fps")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Form {
                    Picker("字幕", selection: $options.kind) {
                        Text("原文").tag(SRTOutputKind.source)
                        Text("译文").tag(SRTOutputKind.translation)
                        Text("双语").tag(SRTOutputKind.bilingual)
                    }
                    Picker("编码", selection: $options.codec) {
                        ForEach(BurnInCodec.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("质量", selection: $options.quality) {
                        ForEach(BurnInQuality.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Stepper("字号：\(Int(options.fontSize))（1080p 基准）", value: $options.fontSize, in: 16...72, step: 2)
                    Text("底部居中 · 白字深色背景 · SDR\n使用本次校对字幕与所选音轨，输出新的 MP4。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(isPreparing || isExporting)
                .frame(width: 340)
            }
            TextField("输出文件名", text: $fileName).textFieldStyle(.roundedBorder).disabled(isExporting)
            HStack {
                Text(targetDirectory?.path ?? "请选择保存目录").lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("选择目录…") { showDirectoryPicker = true }.disabled(isExporting)
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            if isExporting { ProgressView(value: progress) }
            if let exportedURL {
                Label("已导出：\(exportedURL.lastPathComponent)", systemImage: "checkmark.circle.fill")
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([exportedURL]) }
            }
            HStack {
                if isPreparing || isExporting {
                    Button("取消") { operation?.cancel() }
                    Text(isExporting ? "正在烧录 \(Int(progress * 100))%" : "正在准备画面…").font(.caption)
                }
                Spacer()
                Button("烧录并导出") { startExport(allowOverwrite: false) }
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
        .alert("输出文件已存在", isPresented: $showOverwriteAlert) {
            Button("取消", role: .cancel) {}
            Button("覆盖并导出", role: .destructive) { startExport(allowOverwrite: true) }
        } message: { Text("是否覆盖“\(fileName)”？原视频始终保留。") }
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
                errorMessage = error is CancellationError ? "预览已取消。" : error.localizedDescription
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
            catch { errorMessage = error is CancellationError ? "烧录已取消，未发布输出文件。" : error.localizedDescription }
        }
    }
}

#endif
