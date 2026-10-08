#if os(iOS)
import AVKit
import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore
import VoxlineMedia

public struct IOSSubtitleEmbeddingSheet: View {
    private let itemSnapshot: TaskMediaItem
    private let task: ProcessingTask?
    @Environment(\.dismiss) private var dismiss

    @State private var selectedKind: SRTOutputKind
    @State private var fileName: String
    @State private var errorMessage: String?
    @State private var exportedURL: URL?
    @State private var isExporting = false
    @State private var progress: Double = 0
    @State private var exportTask: Task<Void, Never>?
    @State private var showPreviewPlayer = false

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
        NavigationStack {
            Form {
                Section(String(localized: "字幕类型", bundle: appLocalizationBundle)) {
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
                        Text(String(localized: "有 \(missingTranslationCount) 条字幕缺少有效译文。请完成翻译或校对后导出，或选择原文。", bundle: appLocalizationBundle))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section(String(localized: "输出设置", bundle: appLocalizationBundle)) {
                    TextField(String(localized: "输出文件名", bundle: appLocalizationBundle), text: $fileName)
                        .disabled(isExporting)
                        .onChange(of: fileName) { _, _ in
                            exportedURL = nil
                            errorMessage = nil
                        }

                    LabeledContent(String(localized: "字幕语言", bundle: appLocalizationBundle), value: selectedLanguageTag)
                    LabeledContent(String(localized: "字幕条数", bundle: appLocalizationBundle), value: String(localized: "\(itemSnapshot.cues.count) 条", bundle: appLocalizationBundle))
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "• 软字幕无损直通音视频画面，并在 MP4 内嵌入独立字幕轨。", bundle: appLocalizationBundle))
                        Text(String(localized: "• 导出无需重新编码画面，耗时极短，画质零损耗。", bundle: appLocalizationBundle))
                        Text(String(localized: "• 支持在播放器中自由开启或关闭字幕。", bundle: appLocalizationBundle))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if isExporting {
                    Section(String(localized: "导出进度", bundle: appLocalizationBundle)) {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: progress)
                            HStack {
                                Text(String(localized: "正在封装软字幕 \(Int(progress * 100))%…", bundle: appLocalizationBundle))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button(String(localized: "取消", bundle: appLocalizationBundle)) {
                                    exportTask?.cancel()
                                }
                                .font(.caption)
                            }
                        }
                    }
                }

                if let exportedURL {
                    Section(String(localized: "导出成果", bundle: appLocalizationBundle)) {
                        Label(String(localized: "已生成软字幕视频", bundle: appLocalizationBundle), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)

                        Button {
                            showPreviewPlayer = true
                        } label: {
                            Label(String(localized: "在播放器中预览", bundle: appLocalizationBundle), systemImage: "play.circle")
                        }

                        ShareLink(item: exportedURL) {
                            Label(String(localized: "分享或存储到“文件”…", bundle: appLocalizationBundle), systemImage: "square.and.arrow.up")
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }

                if exportedURL == nil && !isExporting {
                    Section {
                        Button {
                            startExport()
                        } label: {
                            HStack {
                                Spacer()
                                Text(String(localized: "开始导出内封软字幕", bundle: appLocalizationBundle))
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                        }
                        .disabled(itemSnapshot.cues.isEmpty || (selectedKind != .source && missingTranslationCount > 0))
                    }
                }
            }
            .navigationTitle(String(localized: "内封软字幕视频", bundle: appLocalizationBundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "关闭", bundle: appLocalizationBundle)) { dismiss() }
                        .disabled(isExporting)
                }
                if let exportedURL {
                    ToolbarItem(placement: .confirmationAction) {
                        ShareLink(item: exportedURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            .sheet(isPresented: $showPreviewPlayer) {
                if let exportedURL {
                    VideoPlayerView(url: exportedURL)
                }
            }
            .onDisappear {
                exportTask?.cancel()
            }
        }
    }

    private func startExport() {
        errorMessage = nil
        exportedURL = nil
        isExporting = true
        progress = 0

        let sanitizedName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(sanitizedName)
        let kind = selectedKind
        let tag = selectedLanguageTag
        let snapshot = itemSnapshot

        exportTask = Task { @MainActor in
            defer {
                isExporting = false
                exportTask = nil
            }
            do {
                try await SubtitleEmbeddingExporter.export(
                    item: snapshot,
                    kind: kind,
                    to: destination,
                    languageTag: tag,
                    allowOverwrite: true,
                    progress: { p in
                        progress = p
                    }
                )
                exportedURL = destination
            } catch is CancellationError {
                errorMessage = String(localized: "导出已取消。", bundle: appLocalizationBundle)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct VideoPlayerView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VideoPlayer(player: AVPlayer(url: url))
                .ignoresSafeArea()
                .navigationTitle(String(localized: "视频预览", bundle: appLocalizationBundle))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "完成", bundle: appLocalizationBundle)) { dismiss() }
                    }
                }
        }
    }
}
#endif
