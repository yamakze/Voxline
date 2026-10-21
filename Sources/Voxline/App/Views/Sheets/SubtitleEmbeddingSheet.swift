#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore
import VoxlineMedia

public struct SubtitleEmbeddingSheet: View {
    private let itemSnapshot: TaskMediaItem
    @Environment(\.dismiss) private var dismiss
    @State private var session: SubtitleEmbeddingSession

    @State private var targetDirectory: URL?
    @State private var showDirectoryPicker = false

    public init(item: TaskMediaItem, task: ProcessingTask? = nil) {
        self.itemSnapshot = item
        _session = State(initialValue: SubtitleEmbeddingSession(item: item, task: task))
    }

    public var body: some View {
        @Bindable var session = session
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.voxlineAccent.opacity(0.12))
                    Image(systemName: "film.stack")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.voxlineAccent)
                }
                .frame(width: 24, height: 24)
                Text(String(localized: "内封软字幕视频", bundle: appLocalizationBundle))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background {
                Color(nsColor: .windowBackgroundColor).opacity(0.7)
                    .background(.regularMaterial)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.4)).frame(height: 1)
            }

            VStack(alignment: .leading, spacing: 16) {
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
                    Label(String(localized: "有 \(session.missingTranslationCount) 条字幕缺少有效译文。请完成翻译或校对后导出，或选择原文。", bundle: appLocalizationBundle), systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "输出文件名", bundle: appLocalizationBundle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(String(localized: "输出文件名", bundle: appLocalizationBundle), text: $session.fileName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(session.isExporting)
                        .onChange(of: session.fileName) { _, _ in
                            session.exportedURL = nil
                            session.errorMessage = nil
                        }
                }

                HStack {
                    Text(targetDirectory?.path ?? String(localized: "请选择保存目录", bundle: appLocalizationBundle))
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(String(localized: "选择目录…", bundle: appLocalizationBundle)) { showDirectoryPicker = true }
                        .disabled(session.isExporting)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "• 软字幕无损直通音视频画面，并在 MP4 内嵌入独立字幕轨。", bundle: appLocalizationBundle))
                    Text(String(localized: "• 导出无需重新编码画面，耗时极短，画质零损耗。", bundle: appLocalizationBundle))
                    Text(String(localized: "• 支持在 QuickTime Player、VLC 等现代播放器中随时开启或关闭字幕。", bundle: appLocalizationBundle))
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if session.isExporting {
                    SubtitleEmbeddingProgress(session: session)
                }

                if let errorMessage = session.errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                if let exportedURL = session.exportedURL {
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
            .padding(20)

            HStack {
                Text(String(localized: "\(itemSnapshot.cues.count) 条字幕", bundle: appLocalizationBundle))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "取消", bundle: appLocalizationBundle)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(session.isExporting)
                Button(String(localized: "导出软字幕", bundle: appLocalizationBundle)) {
                    startExport(allowOverwrite: false)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(targetDirectory == nil || session.isExporting || itemSnapshot.cues.isEmpty || (session.selectedKind != .source && session.missingTranslationCount > 0))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background {
                Color(nsColor: .windowBackgroundColor).opacity(0.7)
                    .background(.regularMaterial)
            }
            .overlay(alignment: .top) {
                Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.4)).frame(height: 1)
            }
        }
        .frame(width: 540)
        .onDisappear {
            session.cancel()
        }
        .fileImporter(isPresented: $showDirectoryPicker, allowedContentTypes: [.folder]) { result in
            do {
                targetDirectory = try result.get()
                session.errorMessage = nil
                session.exportedURL = nil
            } catch {
                session.errorMessage = error.localizedDescription
            }
        }
        .alert(String(localized: "输出文件已存在", bundle: appLocalizationBundle), isPresented: $session.requiresOverwriteConfirmation) {
            Button(String(localized: "取消", bundle: appLocalizationBundle), role: .cancel) {}
            Button(String(localized: "覆盖并导出", bundle: appLocalizationBundle), role: .destructive) {
                startExport(allowOverwrite: true)
            }
        } message: {
            Text(String(localized: "目录中已存在名为“\(session.fileName)”的文件。是否确认覆盖？原视频始终保留。", bundle: appLocalizationBundle))
        }
    }

    private func startExport(allowOverwrite: Bool) {
        guard let directory = targetDirectory else { return }
        session.startExport(to: directory.appendingPathComponent(session.fileName), accessDirectory: directory, allowOverwrite: allowOverwrite)
    }
}

private struct SubtitleEmbeddingProgress: View {
    let session: SubtitleEmbeddingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: session.progress)
            HStack {
                Text(String(localized: "正在封装软字幕 \(Int(session.progress * 100))%…", bundle: appLocalizationBundle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "取消", bundle: appLocalizationBundle)) { session.cancel() }
                    .controlSize(.small)
            }
        }
    }
}
#endif
