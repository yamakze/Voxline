#if os(iOS)
import AVKit
import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore
import VoxlineMedia

public struct IOSSubtitleEmbeddingSheet: View {
    private let itemSnapshot: TaskMediaItem
    @Environment(\.dismiss) private var dismiss
    @State private var session: SubtitleEmbeddingSession

    @State private var showPreviewPlayer = false

    public init(item: TaskMediaItem, task: ProcessingTask? = nil) {
        self.itemSnapshot = item
        _session = State(initialValue: SubtitleEmbeddingSession(item: item, task: task))
    }

    public var body: some View {
        @Bindable var session = session
        NavigationStack {
            Form {
                Section(String(localized: "字幕类型", bundle: appLocalizationBundle)) {
                    Picker(String(localized: "字幕类型", bundle: appLocalizationBundle), selection: $session.selectedKind) {
                        Text(String(localized: "原文", bundle: appLocalizationBundle)).tag(SRTOutputKind.source)
                        Text(String(localized: "译文", bundle: appLocalizationBundle)).tag(SRTOutputKind.translation)
                        Text(String(localized: "双语", bundle: appLocalizationBundle)).tag(SRTOutputKind.bilingual)
                    }
                    .pickerStyle(.segmented)
                    .disabled(session.isExporting)
                    .onChange(of: session.selectedKind) { _, _ in
                        session.exportedURL = nil
                        session.errorMessage = nil
                    }

                    if session.selectedKind != .source && session.missingTranslationCount > 0 {
                        Text(String(localized: "有 \(session.missingTranslationCount) 条字幕缺少有效译文。请完成翻译或校对后导出，或选择原文。", bundle: appLocalizationBundle))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section(String(localized: "输出设置", bundle: appLocalizationBundle)) {
                    TextField(String(localized: "输出文件名", bundle: appLocalizationBundle), text: $session.fileName)
                        .disabled(session.isExporting)
                        .onChange(of: session.fileName) { _, _ in
                            session.exportedURL = nil
                            session.errorMessage = nil
                        }

                    LabeledContent(String(localized: "字幕语言", bundle: appLocalizationBundle), value: session.languageTag)
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

                if session.isExporting {
                    IOSSubtitleEmbeddingProgress(session: session)
                }

                if let exportedURL = session.exportedURL {
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

                if let errorMessage = session.errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }

                if session.exportedURL == nil && !session.isExporting {
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
                        .disabled(itemSnapshot.cues.isEmpty || (session.selectedKind != .source && session.missingTranslationCount > 0))
                    }
                }
            }
            .navigationTitle(String(localized: "内封软字幕视频", bundle: appLocalizationBundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "关闭", bundle: appLocalizationBundle)) { dismiss() }
                        .disabled(session.isExporting)
                }
                if let exportedURL = session.exportedURL {
                    ToolbarItem(placement: .confirmationAction) {
                        ShareLink(item: exportedURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            .sheet(isPresented: $showPreviewPlayer) {
                if let exportedURL = session.exportedURL {
                    IOSExportVideoPreview(url: exportedURL)
                }
            }
            .onDisappear {
                session.cancel()
            }
        }
    }

    private func startExport() {
        let name = session.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        session.startExport(to: FileManager.default.temporaryDirectory.appendingPathComponent(name), accessDirectory: FileManager.default.temporaryDirectory, allowOverwrite: true)
    }
}

private struct IOSSubtitleEmbeddingProgress: View {
    let session: SubtitleEmbeddingSession

    var body: some View {
        Section(String(localized: "导出进度", bundle: appLocalizationBundle)) {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: session.progress)
                HStack {
                    Text(String(localized: "正在封装软字幕 \(Int(session.progress * 100))%…", bundle: appLocalizationBundle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(String(localized: "取消", bundle: appLocalizationBundle)) {
                        session.cancel()
                    }
                    .font(.caption)
                }
            }
        }
    }
}
#endif
