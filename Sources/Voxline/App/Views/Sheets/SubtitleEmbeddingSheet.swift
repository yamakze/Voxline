#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore
import VoxlineMedia

public struct SubtitleEmbeddingSheet: View {
    private let itemSnapshot: TaskMediaItem
    private let task: ProcessingTask?
    @Environment(\.dismiss) private var dismiss

    @State private var selectedKind: SRTOutputKind
    @State private var fileName: String
    @State private var targetDirectory: URL?
    @State private var showDirectoryPicker = false
    @State private var showOverwriteAlert = false
    @State private var errorMessage: String?
    @State private var exportedURL: URL?
    @State private var isExporting = false
    @State private var progress: Double = 0
    @State private var exportTask: Task<Void, Never>?

    public init(item: TaskMediaItem, task: ProcessingTask? = nil) {
        self.itemSnapshot = item
        self.task = task
        let defaultKind: SRTOutputKind = item.cues.allSatisfy(\.hasCurrentTranslation) ? .bilingual : .source
        _selectedKind = State(initialValue: defaultKind)
        let base = ((item.media?.fileName ?? item.title) as NSString).deletingPathExtension
        _fileName = State(initialValue: "\(base).embedded.mp4")
    }

    private var missingTranslationCount: Int {
        itemSnapshot.cues.filter { !$0.hasCurrentTranslation }.count
    }

    private var selectedLanguageTag: String {
        switch selectedKind {
        case .source:
            if let code = task?.parameters.transcription.languageCode, !code.isEmpty {
                return code
            }
            return "und"
        case .translation, .bilingual:
            if let target = task?.parameters.translation?.targetLanguage, !target.isEmpty {
                return target
            }
            return "und"
        }
    }

    public var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("内封软字幕视频").font(.headline)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 16) {
                Picker("字幕类型", selection: $selectedKind) {
                    Text("原文").tag(SRTOutputKind.source)
                    Text("译文").tag(SRTOutputKind.translation)
                    Text("双语").tag(SRTOutputKind.bilingual)
                }
                .pickerStyle(.segmented)
                .disabled(isExporting)
                .onChange(of: selectedKind) { _, _ in
                    exportedURL = nil
                    errorMessage = nil
                }

                if selectedKind != .source && missingTranslationCount > 0 {
                    Label("有 \(missingTranslationCount) 条字幕缺少有效译文。请完成翻译或校对后导出，或选择原文。", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("输出文件名")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("输出文件名", text: $fileName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isExporting)
                        .onChange(of: fileName) { _, _ in
                            exportedURL = nil
                            errorMessage = nil
                        }
                }

                HStack {
                    Text(targetDirectory?.path ?? "请选择保存目录")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("选择目录…") { showDirectoryPicker = true }
                        .disabled(isExporting)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("• 软字幕无损直通音视频画面，并在 MP4 内嵌入独立字幕轨。")
                    Text("• 导出无需重新编码画面，耗时极短，画质零损耗。")
                    Text("• 支持在 QuickTime Player、VLC 等现代播放器中随时开启或关闭字幕。")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if isExporting {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: progress)
                        HStack {
                            Text("正在封装软字幕 \(Int(progress * 100))%…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("取消") {
                                exportTask?.cancel()
                            }
                            .controlSize(.small)
                        }
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                if let exportedURL {
                    HStack {
                        Label("已导出：\(exportedURL.lastPathComponent)", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                        Spacer()
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding()
            .liquidGlassSurface()

            HStack {
                Text("\(itemSnapshot.cues.count) 条字幕")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isExporting)
                Button("导出软字幕") {
                    startExport(allowOverwrite: false)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(targetDirectory == nil || isExporting || itemSnapshot.cues.isEmpty || (selectedKind != .source && missingTranslationCount > 0))
            }
        }
        .padding(24)
        .frame(width: 540)
        .onDisappear {
            exportTask?.cancel()
        }
        .fileImporter(isPresented: $showDirectoryPicker, allowedContentTypes: [.folder]) { result in
            do {
                targetDirectory = try result.get()
                errorMessage = nil
                exportedURL = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .alert("输出文件已存在", isPresented: $showOverwriteAlert) {
            Button("取消", role: .cancel) {}
            Button("覆盖并导出", role: .destructive) {
                startExport(allowOverwrite: true)
            }
        } message: {
            Text("目录中已存在名为“\(fileName)”的文件。是否确认覆盖？原视频始终保留。")
        }
    }

    private func startExport(allowOverwrite: Bool) {
        guard let directory = targetDirectory else { return }
        errorMessage = nil
        exportedURL = nil
        isExporting = true
        progress = 0

        let destination = directory.appendingPathComponent(fileName)
        let kind = selectedKind
        let tag = selectedLanguageTag
        let snapshot = itemSnapshot

        let accessing = directory.startAccessingSecurityScopedResource()

        exportTask = Task { @MainActor in
            defer {
                if accessing { directory.stopAccessingSecurityScopedResource() }
                isExporting = false
                exportTask = nil
            }
            do {
                try await SubtitleEmbeddingExporter.export(
                    item: snapshot,
                    kind: kind,
                    to: destination,
                    languageTag: tag,
                    allowOverwrite: allowOverwrite,
                    progress: { p in
                        progress = p
                    }
                )
                exportedURL = destination
            } catch is CancellationError {
                errorMessage = "导出已取消。"
            } catch BurnInError.fileAlreadyExists {
                showOverwriteAlert = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
#endif
