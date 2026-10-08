#if os(iOS)
import AVKit
import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore
import VoxlineMedia

struct IOSSubtitleBurnInSheet: View {
    @State private var item: TaskMediaItem
    @Environment(\.dismiss) private var dismiss
    @State private var options = BurnInOptions()
    @State private var plan: SubtitleBurnInPlan?
    @State private var previewImage: UIImage?
    @State private var previewTime: Int64 = 0
    @State private var fileName: String
    @State private var errorMessage: String?
    @State private var exportedURL: URL?
    @State private var isPreparing = false
    @State private var isExporting = false
    @State private var progress: Double = 0
    @State private var operation: Task<Void, Never>?
    @State private var showPreviewPlayer = false

    init(item: TaskMediaItem) {
        _item = State(initialValue: item)
        _fileName = State(initialValue: "\(((item.media?.fileName ?? item.title) as NSString).deletingPathExtension).subtitled.mp4")
        _previewTime = State(initialValue: item.cues.first?.startMilliseconds ?? 0)
        _options = State(initialValue: {
            var options = BurnInOptions()
            options.kind = item.cues.allSatisfy(\.hasTranslation) ? .bilingual : .source
            return options
        }())
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
                        .disabled(isExporting)
                }
                if let exportedURL {
                    ToolbarItem(placement: .confirmationAction) {
                        ShareLink(item: exportedURL) {
                            Label(String(localized: "分享视频", bundle: appLocalizationBundle), systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .sheet(isPresented: $showPreviewPlayer) {
                if let exportedURL {
                    VideoPlayerView(url: exportedURL)
                }
            }
            .onChange(of: options) { _, _ in invalidatePreview() }
            .onChange(of: previewTime) { _, _ in previewImage = nil }
            .onDisappear {
                operation?.cancel()
                plan?.releaseAccess()
            }
        }
    }

    private var previewSection: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black)
                    .aspectRatio(16/9, contentMode: .fit)

                if let previewImage {
                    Image(uiImage: previewImage)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "film")
                            .font(.system(size: 32))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(isPreparing ? String(localized: "正在生成预览…", bundle: appLocalizationBundle) : String(localized: "轻点生成画面预览", bundle: appLocalizationBundle))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }

                if isPreparing {
                    Color.black.opacity(0.4)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(maxHeight: 220)

            HStack {
                Picker(String(localized: "预览字幕位置", bundle: appLocalizationBundle), selection: $previewTime) {
                    ForEach(item.cues) { cue in
                        Text("\(formatTime(cue.startMilliseconds)) · \(cue.sourceText.prefix(20))")
                            .tag(cue.startMilliseconds)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .disabled(isPreparing || isExporting)

                Spacer()

                Button {
                    refreshPreview()
                } label: {
                    Label(String(localized: "刷新预览", bundle: appLocalizationBundle), systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isPreparing || isExporting)
            }

            if let plan {
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
                Picker(String(localized: "字幕类型", bundle: appLocalizationBundle), selection: $options.kind) {
                    Text(String(localized: "原文", bundle: appLocalizationBundle)).tag(SRTOutputKind.source)
                    Text(String(localized: "译文", bundle: appLocalizationBundle)).tag(SRTOutputKind.translation)
                    Text(String(localized: "双语", bundle: appLocalizationBundle)).tag(SRTOutputKind.bilingual)
                }
                .pickerStyle(.segmented)
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "视频编码", bundle: appLocalizationBundle))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Picker(String(localized: "视频编码", bundle: appLocalizationBundle), selection: $options.codec) {
                        ForEach(BurnInCodec.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "画面质量", bundle: appLocalizationBundle))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Picker(String(localized: "画面质量", bundle: appLocalizationBundle), selection: $options.quality) {
                        ForEach(BurnInQuality.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(String(localized: "字幕字号（1080p 基准）", bundle: appLocalizationBundle))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(options.fontSize)) pt")
                        .font(.caption.monospacedDigit().bold())
                }
                Slider(value: $options.fontSize, in: 20...60, step: 2)
            }
        }
        .disabled(isPreparing || isExporting)
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }

    private var exportSection: some View {
        VStack(spacing: 12) {
            if let errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if isExporting {
                VStack(spacing: 8) {
                    ProgressView(value: progress)
                    HStack {
                        Text(String(format: String(localized: "正在导出 %.0f%%", bundle: appLocalizationBundle), locale: .current, progress * 100))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(String(localized: "取消", bundle: appLocalizationBundle)) { operation?.cancel() }
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 4)
            } else if let exportedURL {
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

                        ShareLink(item: exportedURL) {
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
                .disabled(isPreparing || isExporting)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
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
                previewImage = UIImage(cgImage: image)
            } catch {
                previewImage = nil
                errorMessage = error is CancellationError ? String(localized: "已取消预览。", bundle: appLocalizationBundle) : error.localizedDescription
            }
        }
    }

    private func startExport() {
        isExporting = true
        progress = 0
        errorMessage = nil
        exportedURL = nil
        operation = Task { @MainActor in
            defer {
                isExporting = false
                operation = nil
            }
            do {
                if plan == nil {
                    plan = try await SubtitleBurnInExporter.composition(for: item, options: options)
                }
                guard let plan else { throw BurnInError.invalidGeometry }

                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("mp4")

                try await SubtitleBurnInExporter.export(plan, to: destination, allowOverwrite: true) { currentProgress in
                    progress = currentProgress
                }
                exportedURL = destination
            } catch {
                errorMessage = error is CancellationError ? String(localized: "已取消导出。", bundle: appLocalizationBundle) : error.localizedDescription
            }
        }
    }

    private func formatTime(_ milliseconds: Int64) -> String {
        Duration.milliseconds(milliseconds).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2)))
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
