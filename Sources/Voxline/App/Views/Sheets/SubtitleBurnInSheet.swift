#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore
import VoxlineMedia

struct SubtitleBurnInSheet: View {
    @State private var session: SubtitleBurnInSession
    @Environment(\.dismiss) private var dismiss
    @State private var isChoosingDestination = false

    init(item: TaskMediaItem) {
        _session = State(initialValue: SubtitleBurnInSession(item: item))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.voxlineAccent.opacity(0.12))
                    Image(systemName: "flame")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.voxlineAccent)
                }
                .frame(width: 24, height: 24)
                Text(String(localized: "烧录字幕视频", bundle: appLocalizationBundle))
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

            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 10) {
                        if let previewImage = session.previewImage {
                            Image(nsImage: NSImage(cgImage: previewImage, size: .zero)).resizable().scaledToFit()
                                .frame(width: 400, height: 240).background(.black)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 0.8))
                        } else {
                            ContentUnavailableView(String(localized: "输出预览", bundle: appLocalizationBundle), systemImage: "film",
                                description: Text(String(localized: "选择字幕和输出设置，生成实际合成画面。", bundle: appLocalizationBundle)))
                                .frame(width: 400, height: 240)
                                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        BurnInPreviewCuePicker(options: session.previewOptions, selection: $session.previewCueID)
                        .disabled(session.isPreparing || session.isExporting || isChoosingDestination)
                        Button(session.isPreparing ? String(localized: "正在生成预览…", bundle: appLocalizationBundle) : String(localized: "更新预览", bundle: appLocalizationBundle)) { session.refreshPreview() }
                            .disabled(session.isPreparing || session.isExporting || isChoosingDestination)
                        if let plan = session.plan {
                            Text("\(Int(plan.renderSize.width)) × \(Int(plan.renderSize.height)) · \(1 / plan.videoComposition.frameDuration.seconds, specifier: "%.2f") fps")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
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
                        LabeledContent(String(localized: "字号", bundle: appLocalizationBundle)) {
                            HStack {
                                Text("\(Int(session.options.fontSize)) pt")
                                    .font(.body.monospacedDigit())
                                Spacer()
                                Stepper("", value: $session.options.fontSize, in: 16...72, step: 2)
                                    .labelsHidden()
                            }
                        }
                    }
                    .disabled(session.isPreparing || session.isExporting || isChoosingDestination)
                    .frame(width: 340)
                }
                if let errorMessage = session.errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
                if session.isExporting { BurnInProgressBar(session: session) }
                if let exportedURL = session.exportedURL {
                    Label(String(localized: "已导出：\(exportedURL.lastPathComponent)", bundle: appLocalizationBundle), systemImage: "checkmark.circle.fill")
                    Button(String(localized: "在 Finder 中显示", bundle: appLocalizationBundle)) { NSWorkspace.shared.activateFileViewerSelecting([exportedURL]) }
                }
            }
            .padding(20)

            HStack {
                if session.isPreparing || session.isExporting {
                    Button(String(localized: "停止", bundle: appLocalizationBundle)) { session.cancel() }
                    BurnInProgressText(session: session)
                }
                Spacer()
                Button(String(localized: "取消", bundle: appLocalizationBundle)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(session.isPreparing || session.isExporting || isChoosingDestination)
                Button(String(localized: "烧录并导出", bundle: appLocalizationBundle)) { startExport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.plan == nil || session.previewImage == nil || session.isPreparing || session.isExporting || isChoosingDestination)
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
        .frame(width: 820)
        .onDisappear { session.close() }
    }

    private func startExport() {
        guard !session.isPreparing, !session.isExporting, !isChoosingDestination else { return }
        isChoosingDestination = true
        Task { @MainActor in
            defer { isChoosingDestination = false }
            guard let url = await MacExportDestinationPicker.choose(
                suggestedName: session.fileName,
                contentType: .mpeg4Movie
            ) else { return }
            session.startExport(to: url, accessDirectory: url, allowOverwrite: true)
        }
    }

}

private struct BurnInProgressBar: View {
    let session: SubtitleBurnInSession

    var body: some View {
        ProgressView(value: session.progress)
    }
}

private struct BurnInProgressText: View {
    let session: SubtitleBurnInSession

    var body: some View {
        Text(session.isExporting
             ? String(localized: "正在烧录 \(Int(session.progress * 100))%", bundle: appLocalizationBundle)
             : String(localized: "正在准备画面…", bundle: appLocalizationBundle))
            .font(.caption)
    }
}

#endif
