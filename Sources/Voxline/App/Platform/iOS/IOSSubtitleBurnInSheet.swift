#if os(iOS)
import AVKit
import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore
import VoxlineMedia

struct IOSSubtitleBurnInSheet: View {
    @State private var session: SubtitleBurnInSession
    private var item: TaskMediaItem { session.item }
    @Environment(\.dismiss) private var dismiss
    @State private var showPreviewPlayer = false
    @State private var sharingFile: TemporaryExportFile?

    init(item: TaskMediaItem) {
        _session = State(initialValue: SubtitleBurnInSession(item: item))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // 画面预览区
                    previewSection

                    // 输出设置
                    optionsSection

                    // 导出操作与进度
                    exportSection
                }
                .padding()
            }
            .navigationTitle(String(localized: "烧录字幕视频", bundle: appLocalizationBundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消", bundle: appLocalizationBundle)) { dismiss() }
                        .disabled(session.isExporting)
                }
                if let file = session.temporaryExport {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { sharingFile = file } label: {
                            Label(String(localized: "分享视频", bundle: appLocalizationBundle), systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .sheet(isPresented: $showPreviewPlayer) {
                if let exportedURL = session.exportedURL {
                    VideoPlayerView(url: exportedURL, retainedFile: session.temporaryExport)
                }
            }
            .sheet(item: $sharingFile) { file in
                ShareActivitySheet(activityItems: [file.url], retainedFile: file)
            }
            .onChange(of: session.options) { _, _ in session.invalidatePreview() }
            .onChange(of: session.previewTime) { _, _ in session.previewImage = nil }
            .onDisappear {
                session.close()
            }
        }
    }

    private var previewSection: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black)
                    .aspectRatio(16/9, contentMode: .fit)

                if let previewImage = session.previewImage {
                    Image(uiImage: UIImage(cgImage: previewImage))
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "film")
                            .font(.system(size: 32))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(session.isPreparing ? String(localized: "正在生成预览…", bundle: appLocalizationBundle) : String(localized: "轻点生成画面预览", bundle: appLocalizationBundle))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }

                if session.isPreparing {
                    Color.black.opacity(0.4)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(maxHeight: 220)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(String(localized: "预览字幕节点", bundle: appLocalizationBundle))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        session.refreshPreview()
                    } label: {
                        Label(String(localized: "刷新预览", bundle: appLocalizationBundle), systemImage: "arrow.clockwise")
                            .font(.caption2.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(session.isPreparing || session.isExporting)
                }

                Menu {
                    Picker(String(localized: "预览字幕位置", bundle: appLocalizationBundle), selection: $session.previewTime) {
                        ForEach(item.cues) { cue in
                            Text("\(formatTime(cue.startMilliseconds)) · \(cue.sourceText)")
                                .tag(cue.startMilliseconds)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.caption)
                            .foregroundStyle(Color.voxlineAccent)

                        let currentText: String = {
                            if let cue = item.cues.first(where: { $0.startMilliseconds == session.previewTime }) ?? item.cues.first {
                                return "\(formatTime(cue.startMilliseconds)) · \(cue.sourceText)"
                            }
                            return String(localized: "选择预览字幕", bundle: appLocalizationBundle)
                        }()

                        Text(currentText)
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(.primary)

                        Spacer()

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .disabled(session.isPreparing || session.isExporting)
            }

            if let plan = session.plan {
                HStack(spacing: 8) {
                    Text("\(Int(plan.renderSize.width)) × \(Int(plan.renderSize.height))")
                    Text("•")
                    Text(String(format: "%.2f fps", 1 / plan.videoComposition.frameDuration.seconds))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }

    private var optionsSection: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "字幕类型", bundle: appLocalizationBundle))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Picker(String(localized: "字幕类型", bundle: appLocalizationBundle), selection: $session.options.kind) {
                    Text(String(localized: "原文", bundle: appLocalizationBundle)).tag(SRTOutputKind.source)
                    Text(String(localized: "译文", bundle: appLocalizationBundle)).tag(SRTOutputKind.translation)
                    Text(String(localized: "双语", bundle: appLocalizationBundle)).tag(SRTOutputKind.bilingual)
                }
                .pickerStyle(.segmented)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "视频编码", bundle: appLocalizationBundle))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Menu {
                        Picker(String(localized: "视频编码", bundle: appLocalizationBundle), selection: $session.options.codec) {
                            ForEach(BurnInCodec.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                    } label: {
                        HStack {
                            Text(session.options.codec.label)
                                .font(.subheadline)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "画面质量", bundle: appLocalizationBundle))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Menu {
                        Picker(String(localized: "画面质量", bundle: appLocalizationBundle), selection: $session.options.quality) {
                            ForEach(BurnInQuality.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                    } label: {
                        HStack {
                            Text(session.options.quality.label)
                                .font(.subheadline)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(String(localized: "字幕字号", bundle: appLocalizationBundle))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(session.options.fontSize)) pt")
                        .font(.caption.monospacedDigit().bold())
                }
                Slider(value: $session.options.fontSize, in: 20...60, step: 2)
            }
        }
        .disabled(session.isPreparing || session.isExporting)
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }

    private var exportSection: some View {
        VStack(spacing: 12) {
            if let errorMessage = session.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if session.isExporting {
                IOSBurnInExportProgress(session: session)
                .padding(.vertical, 4)
            } else if let file = session.temporaryExport {
                VStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(String(localized: "导出完成", bundle: appLocalizationBundle))
                            .font(.subheadline.bold())
                    }

                    HStack(spacing: 12) {
                        Button {
                            showPreviewPlayer = true
                        } label: {
                            Label(String(localized: "预览视频", bundle: appLocalizationBundle), systemImage: "play.circle")
                        }
                        .buttonStyle(.bordered)

                        Button { sharingFile = file } label: {
                            Label(String(localized: "保存或分享", bundle: appLocalizationBundle), systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.vertical, 4)
            } else {
                Button {
                    startExport()
                } label: {
                    HStack {
                        Spacer()
                        Label(String(localized: "开始烧录导出", bundle: appLocalizationBundle), systemImage: "arrow.down.circle.fill")
                            .font(.headline)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.isPreparing || session.isExporting)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }

    private func startExport() {
        do {
            let file = try TemporaryExportFile(fileName: session.fileName)
            session.startExport(to: file.url, accessDirectory: file.directory, allowOverwrite: true, temporaryFile: file)
        } catch { session.errorMessage = error.localizedDescription }
    }

    private func formatTime(_ milliseconds: Int64) -> String {
        Duration.milliseconds(milliseconds).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2)))
    }
}

private struct IOSBurnInExportProgress: View {
    let session: SubtitleBurnInSession

    var body: some View {
        VStack(spacing: 8) {
            ProgressView(value: session.progress)
            HStack {
                Text(String(format: String(localized: "正在导出 %.0f%%", bundle: appLocalizationBundle), locale: .current, session.progress * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "取消", bundle: appLocalizationBundle)) { session.cancel() }
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct VideoPlayerView: View {
    let url: URL
    let retainedFile: TemporaryExportFile?
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
