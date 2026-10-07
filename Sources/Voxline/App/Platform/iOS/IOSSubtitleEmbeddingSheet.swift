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
        NavigationStack {
            Form {
                Section("字幕类型") {
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
                        Text("有 \(missingTranslationCount) 条字幕缺少有效译文。请完成翻译或校对后导出，或选择原文。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("输出设置") {
                    TextField("输出文件名", text: $fileName)
                        .disabled(isExporting)
                        .onChange(of: fileName) { _, _ in
                            exportedURL = nil
                            errorMessage = nil
                        }

                    LabeledContent("字幕语言", value: selectedLanguageTag)
                    LabeledContent("字幕条数", value: "\(itemSnapshot.cues.count) 条")
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("• 软字幕无损直通音视频画面，并在 MP4 内嵌入独立字幕轨。")
                        Text("• 导出无需重新编码画面，耗时极短，画质零损耗。")
                        Text("• 支持在播放器中自由开启或关闭字幕。")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if isExporting {
                    Section("导出进度") {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: progress)
                            HStack {
                                Text("正在封装软字幕 \(Int(progress * 100))%…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("取消") {
                                    exportTask?.cancel()
                                }
                                .font(.caption)
                            }
                        }
                    }
                }

                if let exportedURL {
                    Section("导出成果") {
                        Label("已生成软字幕视频", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)

                        Button {
                            showPreviewPlayer = true
                        } label: {
                            Label("在播放器中预览", systemImage: "play.circle")
                        }

                        ShareLink(item: exportedURL) {
                            Label("分享或存储到“文件”…", systemImage: "square.and.arrow.up")
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
                                Text("开始导出内封软字幕")
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                        }
                        .disabled(itemSnapshot.cues.isEmpty || (selectedKind != .source && missingTranslationCount > 0))
                    }
                }
            }
            .navigationTitle("内封软字幕视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
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
                errorMessage = "导出已取消。"
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
                .navigationTitle("视频预览")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
    }
}
#endif
