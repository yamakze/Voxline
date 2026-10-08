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
        let defaultKind: SRTOutputKind = item.cues.allSatisfy(\.hasTranslation) ? .bilingual : .source
        _selectedKind = State(initialValue: defaultKind)
        let base = ((item.media?.fileName ?? item.title) as NSString).deletingPathExtension
        _fileName = State(initialValue: "\(base).embedded.mp4")
    }

    private var missingTranslationCount: Int {
        itemSnapshot.cues.filter { !$0.hasTranslation }.count
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
                Text(String(localized: "内封软字幕视频", bundle: appLocalizationBundle)).font(.headline)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 16) {
                Picker(String(localized: "字幕类型", bundle: appLocalizationBundle), selection: $selectedKind) {
                    Text(String(localized: "原文", bundle: appLocalizationBundle)).tag(SRTOutputKind.source)
                    Text(String(localized: "译文", bundle: appLocalizationBundle)).tag(SRTOutputKind.translation)
                    Text(String(localized: "双语", bundle: appLocalizationBundle)).tag(SRTOutputKind.bilingual)
                }
                .pickerStyle(.segmented)
                .disabled(isExporting)
                .onChange(of: selectedKind) { _, _ in
                    exportedURL = nil
                    errorMessage = nil
                }

                if selectedKind != .source && missingTranslationCount > 0 {
                    Label(String(localized: "有 \(missingTranslationCount) 条字幕缺少有效译文。请完成翻译或校对后导出，或选择原文。", bundle: appLocalizationBundle), systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "输出文件名", bundle: appLocalizationBundle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(String(localized: "输出文件名", bundle: appLocalizationBundle), text: $fileName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isExporting)
                        .onChange(of: fileName) { _, _ in
                            exportedURL = nil
                            errorMessage = nil
                        }
                }

                HStack {
                    Text(targetDirectory?.path ?? String(localized: "请选择保存目录", bundle: appLocalizationBundle))
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(String(localized: "选择目录…", bundle: appLocalizationBundle)) { showDirectoryPicker = true }
                        .disabled(isExporting)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "• 软字幕无损直通音视频画面，并在 MP4 内嵌入独立字幕轨。", bundle: appLocalizationBundle))
                    Text(String(localized: "• 导出无需重新编码画面，耗时极短，画质零损耗。", bundle: appLocalizationBundle))
                    Text(String(localized: "• 支持在 QuickTime Player、VLC 等现代播放器中随时开启或关闭字幕。", bundle: appLocalizationBundle))
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if isExporting {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: progress)
                        HStack {
                            Text(String(localized: "正在封装软字幕 \(Int(progress * 100))%…", bundle: appLocalizationBundle))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(String(localized: "取消", bundle: appLocalizationBundle)) {
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
                        Label(String(localized: "已导出：\(exportedURL.lastPathComponent)", bundle: appLocalizationBundle), systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                        Spacer()
                        Button(String(localized: "在 Finder 中显示", bundle: appLocalizationBundle)) {
                            NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding()
            .liquidGlassSurface()

            HStack {
                Text(String(localized: "\(itemSnapshot.cues.count) 条字幕", bundle: appLocalizationBundle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "取消", bundle: appLocalizationBundle)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isExporting)
                Button(String(localized: "导出软字幕", bundle: appLocalizationBundle)) {
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
        .alert(String(localized: "输出文件已存在", bundle: appLocalizationBundle), isPresented: $showOverwriteAlert) {
            Button(String(localized: "取消", bundle: appLocalizationBundle), role: .cancel) {}
            Button(String(localized: "覆盖并导出", bundle: appLocalizationBundle), role: .destructive) {
                startExport(allowOverwrite: true)
            }
        } message: {
            Text(String(localized: "目录中已存在名为“\(fileName)”的文件。是否确认覆盖？原视频始终保留。", bundle: appLocalizationBundle))
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
                errorMessage = String(localized: "导出已取消。", bundle: appLocalizationBundle)
            } catch BurnInError.fileAlreadyExists {
                showOverwriteAlert = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
#endif
