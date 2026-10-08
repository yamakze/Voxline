#if os(macOS)
import VoxlineWorkflow
import SwiftUI
import AVKit
import Observation
import VoxlineCore
import VoxlineMedia

public struct MediaDetailProofreadingView: View {
    let taskID: UUID
    let initialOutputKind: SRTOutputKind
    let item: TaskMediaItem
    let onCommit: (TaskMediaItem, TaskMediaItem) throws -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playbackController = MediaPlaybackController()
    @State private var previewMode: SRTOutputKind = .bilingual
    @State private var searchQuery: String = ""
    @State private var hoveredCueID: UUID?
    @State private var errorMessage: String?
    @State private var editingCueID: UUID?
    @State private var editingSnapshot: SubtitleCue?
    @State private var sourceDraft = ""
    @State private var translationDraft = ""
    @State private var retranslationCues: [SubtitleCue]?
    @State private var queue = TaskProcessingQueue.shared

    // Sheets
    @State private var showTimeOffsetSheet = false
    @State private var showSRTExportSheet = false
    @State private var showEmbeddingSheet = false
    @State private var showBurnInSheet = false
    @State private var showRelinkSheet = false

    public var onBack: (() -> Void)?

    public init(taskID: UUID, initialOutputKind: SRTOutputKind, item: TaskMediaItem, onCommit: @escaping (TaskMediaItem, TaskMediaItem) throws -> Void, onBack: (() -> Void)? = nil) {
        self.taskID = taskID
        self.initialOutputKind = initialOutputKind
        self.item = item
        self.onCommit = onCommit
        self.onBack = onBack
        let hasTranslation = item.cues.contains { cue in
            if case .succeeded = cue.translation { return true }
            return false
        }
        _previewMode = State(initialValue: hasTranslation ? .bilingual : .source)
    }

    private var filteredCues: [SubtitleCue] {
        if searchQuery.isEmpty { return item.cues }
        let q = searchQuery.lowercased()
        return item.cues.filter { cue in
            if cue.sourceText.lowercased().contains(q) { return true }
            if case .succeeded(let trans, _) = cue.translation, trans.lowercased().contains(q) { return true }
            return false
        }
    }

    public var body: some View {
        let activeCue = playbackController.activeCue(in: item.cues)
        HSplitView {
            // Left Column: QuickTime Player with Floating Glass Capsule Controls
            quickTimePlayerPane(activeCue: activeCue)
                .frame(minWidth: 440, idealWidth: 540)
                .frame(maxHeight: .infinity)

            // Right Column: Apple Podcasts Lyrics/Transcript Stream
            podcastsTranscriptPane(activeCueID: activeCue?.id)
                .frame(minWidth: 460, idealWidth: 580)
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            if let onBack {
                ToolbarItem(placement: .navigation) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                    }
                    .help(String(localized: "返回任务队列", bundle: appLocalizationBundle))
                }
            }

            ToolbarItem(placement: .principal) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if queue.taskID == taskID, queue.mediaID == item.id {
                    Text(queue.progressText ?? String(localized: "处理中", bundle: appLocalizationBundle)).font(.caption)
                    Button(queue.isCancelling ? String(localized: "正在取消…", bundle: appLocalizationBundle) : String(localized: "取消处理", bundle: appLocalizationBundle)) {
                        do { try queue.cancel(mediaID: item.id) }
                        catch { errorMessage = error.localizedDescription }
                    }
                    .disabled(queue.isCancelling)
                } else {
                    Button(String(localized: "重译字幕…", bundle: appLocalizationBundle), systemImage: "character.bubble") { retranslationCues = item.cues }
                        .disabled(item.cues.isEmpty || editingCueID != nil || queue.taskID != nil)
                }

                Button(String(localized: "重新关联", bundle: appLocalizationBundle), systemImage: "link.badge.plus") {
                    showRelinkSheet = true
                }
                .disabled(queue.taskID != nil)

                Button(String(localized: "偏移行…", bundle: appLocalizationBundle), systemImage: "timer") {
                    showTimeOffsetSheet = true
                }
                .disabled(item.cues.isEmpty || editingCueID != nil)

                Menu {
                    Section(String(localized: "外挂字幕", bundle: appLocalizationBundle)) {
                        Button {
                            showSRTExportSheet = true
                        } label: {
                            Label(String(localized: "导出字幕文件…", bundle: appLocalizationBundle), systemImage: "doc.text")
                        }
                    }

                    if item.kind == .video {
                        Section(String(localized: "视频内嵌", bundle: appLocalizationBundle)) {
                            Button {
                                showEmbeddingSheet = true
                            } label: {
                                Label(String(localized: "内封软字幕…", bundle: appLocalizationBundle), systemImage: "captions.bubble")
                            }

                            Button {
                                showBurnInSheet = true
                            } label: {
                                Label(String(localized: "烧录硬字幕…", bundle: appLocalizationBundle), systemImage: "film.stack")
                            }
                        }
                    }
                } label: {
                    Label(String(localized: "导出", bundle: appLocalizationBundle), systemImage: "square.and.arrow.up")
                }
                .disabled(item.cues.isEmpty || editingCueID != nil)
                .help(String(localized: "导出字幕或包含字幕的媒体文件", bundle: appLocalizationBundle))
            }
        }
        .alert(String(localized: "无法完成操作", bundle: appLocalizationBundle), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button(String(localized: "好", bundle: appLocalizationBundle), role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .task(id: MediaPlaybackController.SourceIdentity(item: item)) {
            await playbackController.loadMedia(for: item)
        }
        .onDisappear {
            playbackController.releaseMedia()
        }
        .sheet(isPresented: $showTimeOffsetSheet) {
            TimeOffsetSheet(
                cues: item.cues,
                mediaDurationMilliseconds: item.media?.durationMilliseconds
            ) { shifted, originalCues in
                guard item.cues == originalCues else { throw CheckpointError.editedCue }
                var updated = item
                updated.cues = shifted
                try onCommit(updated, item)
            }
        }
        .sheet(isPresented: $showSRTExportSheet) {
            SRTExportSheet(
                mediaTitle: item.media?.fileName ?? item.title,
                cues: item.cues, media: item.media, initialKind: initialOutputKind
            )
        }
        .sheet(isPresented: $showEmbeddingSheet) {
            SubtitleEmbeddingSheet(item: item, task: TaskLibrary.shared.task(for: taskID))
        }
        .sheet(isPresented: $showBurnInSheet) { SubtitleBurnInSheet(item: item) }
        .sheet(isPresented: $showRelinkSheet, onDismiss: {
            Task { await playbackController.loadMedia(for: item) }
        }) {
            MediaRelinkSheet(item: item, onCommit: onCommit)
        }
        .confirmationDialog(String(localized: "重新翻译全部字幕？", bundle: appLocalizationBundle),
                            isPresented: Binding(get: { retranslationCues != nil }, set: { if !$0 { retranslationCues = nil } }), titleVisibility: .visible) {
            if let selected = retranslationCues {
                Button(String(localized: "重新翻译", bundle: appLocalizationBundle)) {
                    do { try queue.startRetranslation(taskID: taskID, mediaID: item.id, cueIDs: selected.map(\.id)) }
                    catch { errorMessage = error.localizedDescription }
                }
            }
            Button(String(localized: "取消", bundle: appLocalizationBundle), role: .cancel) {}
        }

    }

    private func translationStatus(for cue: SubtitleCue) -> String {
        if case .failed = cue.translation { return String(localized: "翻译失败", bundle: appLocalizationBundle) }
        return String(localized: "未翻译", bundle: appLocalizationBundle)
    }

    // MARK: - QuickTime Player Pane (with Floating Glass Capsule)
    private func quickTimePlayerPane(activeCue: SubtitleCue?) -> some View {
        ZStack(alignment: .bottom) {
            // Video or Audio Canvas
            Group {
                if let player = playbackController.player, playbackController.isReady {
                    if item.kind == .video {
                        NativeVideoPlayer(player: player)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black)
                    } else {
                        // Podcasts Audio artwork style
                        ZStack {
                            Color(nsColor: .windowBackgroundColor)
                            VStack(spacing: 14) {
                                ZStack {
                                    Circle()
                                        .fill(LinearGradient(colors: [.purple.opacity(0.8), .blue.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 140, height: 140)
                                        .shadow(color: .purple.opacity(0.3), radius: 20, y: 10)
                                    Image(systemName: "waveform")
                                        .font(.system(size: 60, weight: .light))
                                        .foregroundStyle(.white)
                                }
                                Text(item.title)
                                    .font(.title3.bold())
                                Text(String(localized: "本地原生音频 · 逐句同步", bundle: appLocalizationBundle))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    // Loading and actual media failures
                    ZStack {
                        Color.black.opacity(0.9)
                        VStack(spacing: 12) {
                            if playbackController.isLoading {
                                ProgressView(String(localized: "正在加载媒体…", bundle: appLocalizationBundle))
                                    .foregroundStyle(.white)
                            } else {
                                Image(systemName: item.kind == .video ? "video.badge.plus" : "waveform.badge.plus")
                                    .font(.system(size: 48))
                                    .foregroundStyle(.white.opacity(0.6))
                                Text(item.media == nil ? String(localized: "媒体待关联", bundle: appLocalizationBundle) : String(localized: "无法播放媒体", bundle: appLocalizationBundle))
                                    .font(.headline).foregroundStyle(.white)
                                Text(playbackController.errorMessage ?? String(localized: "请点击重新关联指定本地原文件。", bundle: appLocalizationBundle))
                                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 24)

                                HStack {
                                    Button(String(localized: "重新关联", bundle: appLocalizationBundle), systemImage: "link") { showRelinkSheet = true }
                                    if item.media != nil {
                                        Button(String(localized: "重试播放", bundle: appLocalizationBundle), systemImage: "arrow.clockwise") {
                                            Task { await playbackController.loadMedia(for: item) }
                                        }
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            // Top Media Metadata Pill (Native Floating HUD)
            VStack {
                HStack(spacing: 8) {
                    Label(item.kind == .video ? String(localized: "视频", bundle: appLocalizationBundle) : String(localized: "音频", bundle: appLocalizationBundle), systemImage: item.kind == .video ? "film" : "waveform")
                    if let media = item.media {
                        Text(String(format: "%.1fs", Double(media.durationMilliseconds) / 1000.0))
                        Text(String(localized: "轨 \(media.audioTrackID)", bundle: appLocalizationBundle))
                    }
                    Text(String(localized: "\(item.cues.count) 句字幕", bundle: appLocalizationBundle))
                    MediaStatusBadge(status: item.status)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: .capsule)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()
            }

            // Active Subtitle HUD Overlay (QuickTime cinema subtitle overlay)
            if playbackController.isReady, let activeCue = activeCue {
                VStack(spacing: 4) {
                    switch previewMode {
                    case .source:
                        Text(activeCue.sourceText)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    case .translation:
                        if case .succeeded(let trans, _) = activeCue.translation {
                            Text(trans)
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                        } else {
                            Text(translationStatus(for: activeCue))
                                .font(.caption).foregroundStyle(.orange)
                        }
                    case .bilingual:
                        Text(activeCue.sourceText)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                        if case .succeeded(let trans, _) = activeCue.translation {
                            Text(trans)
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(.yellow)
                        } else {
                            Text(translationStatus(for: activeCue))
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .subtitleOverlaySurface()
                .padding(.bottom, 78) // Positioned above floating capsule
                .padding(.horizontal, 24)
                .transition(reduceMotion ? .identity : .opacity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: activeCue.id)
            }

            // QuickTime Floating Glass Capsule Controls Bar
            floatingCapsuleControls
                .padding(.bottom, 16)
                .padding(.horizontal, 20)
        }
    }

    // MARK: - QuickTime Floating Glass Capsule Controls
    private var floatingCapsuleControls: some View {
        HStack(spacing: 14) {
            // Play / Pause Button
            Button {
                playbackController.togglePlayPause()
            } label: {
                Image(systemName: playbackController.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playbackController.isPlaying ? String(localized: "暂停", bundle: appLocalizationBundle) : String(localized: "播放", bundle: appLocalizationBundle))

            // Skip -5s / +5s
            Button {
                playbackController.seekRelative(by: -5.0)
            } label: {
                Image(systemName: "gobackward.5")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)

            Button {
                playbackController.seekRelative(by: 5.0)
            } label: {
                Image(systemName: "goforward.5")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)

            // Time Capsule Pill
            Text(playbackController.formattedCurrentTime)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)

            // Fine Scrubber Bar
            Slider(
                value: Binding(
                    get: { playbackController.currentTimeSeconds },
                    set: { playbackController.seek(to: $0) }
                ),
                in: 0...max(playbackController.durationSeconds, 1.0)
            )
            .controlSize(.mini)
            .accessibilityLabel(String(localized: "播放进度", bundle: appLocalizationBundle))
            .frame(minWidth: 100)

            Text(playbackController.formattedDuration)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)

            // Speed Menu
            Menu {
                Button("0.5x") { playbackController.setRate(0.5) }
                Button("0.75x") { playbackController.setRate(0.75) }
                Button(String(localized: "1.0x (正常)", bundle: appLocalizationBundle)) { playbackController.setRate(1.0) }
                Button("1.25x") { playbackController.setRate(1.25) }
                Button("1.5x") { playbackController.setRate(1.5) }
                Button("2.0x") { playbackController.setRate(2.0) }
            } label: {
                Text(String(format: "%.2fx", playbackController.playbackRate))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: .capsule)
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .liquidGlassCapsule()
        .disabled(!playbackController.isReady)
    }

    // MARK: - Apple Podcasts Lyrics/Transcript Pane
    private func podcastsTranscriptPane(activeCueID: UUID?) -> some View {
        VStack(spacing: 0) {
            // Transcript Controls Toolbar (Podcasts style)
            HStack(spacing: 12) {
                Picker(String(localized: "模式", bundle: appLocalizationBundle), selection: $previewMode) {
                    Text(String(localized: "原文", bundle: appLocalizationBundle)).tag(SRTOutputKind.source)
                    Text(String(localized: "译文", bundle: appLocalizationBundle)).tag(SRTOutputKind.translation)
                    Text(String(localized: "双语", bundle: appLocalizationBundle)).tag(SRTOutputKind.bilingual)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(String(localized: "在字幕中搜索…", bundle: appLocalizationBundle), text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.caption)
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1), in: .capsule)
                .frame(width: 170)

                if previewMode != .source, item.cues.contains(where: { !$0.hasTranslation }) {
                    Text(String(localized: "未完成翻译可返回队列重试", bundle: appLocalizationBundle))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)

            Divider()

            // Lyrics / Transcript Stream with Focus Centering
            if item.cues.isEmpty {
                ContentUnavailableView(
                    String(localized: "暂无逐句字幕", bundle: appLocalizationBundle),
                    systemImage: "quote.bubble",
                    description: Text(String(localized: "当前媒体条目尚未转写生成字幕。", bundle: appLocalizationBundle))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(filteredCues) { cue in
                                let isActive = cue.id == activeCueID
                                let isHovered = cue.id == hoveredCueID
                                let isEditing = cue.id == editingCueID
                                let isPast = Double(cue.endMilliseconds) <= playbackController.currentTimeSeconds * 1000

                                transcriptRow(
                                    cue: cue,
                                    isActive: isActive,
                                    isHovered: isHovered,
                                    isEditing: isEditing,
                                    isPast: isPast
                                )
                                .id(cue.id)
                                .onHover { hovering in
                                    hoveredCueID = hovering ? cue.id : nil
                                }
                            }
                        }
                        .padding(.vertical, 40)
                        .padding(.horizontal, 24)
                    }
                    .onChange(of: activeCueID) { _, newActiveID in
                        if let newActiveID {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(newActiveID, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Transcript Row (Podcasts/Apple Music lyrics style)
    @ViewBuilder
    private func transcriptRow(
        cue: SubtitleCue,
        isActive: Bool,
        isHovered: Bool,
        isEditing: Bool,
        isPast: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Timestamp and Hover Actions Bar
            HStack(spacing: 8) {
                // Timestamp button
                Button {
                    playbackController.seek(toMilliseconds: cue.startMilliseconds)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isActive ? "speaker.wave.2.fill" : "play.fill")
                            .font(.system(size: 9))
                        Text(String(format: "%02d:%02d.%03d",
                                    cue.startMilliseconds / 60000,
                                    (cue.startMilliseconds % 60000) / 1000,
                                    cue.startMilliseconds % 1000))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        isActive ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12),
                        in: .capsule
                    )
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                if isEditing {
                    Button(String(localized: "取消编辑", bundle: appLocalizationBundle)) { editingCueID = nil; editingSnapshot = nil }
                        .buttonStyle(.plain)
                }
                Button {
                    if isEditing {
                        do {
                            guard let snapshot = editingSnapshot else { throw CheckpointError.editedCue }
                            var updated = item
                            try updated.editSubtitle(comparedTo: snapshot, sourceText: sourceDraft, translationText: translationDraft)
                            try onCommit(updated, item)
                            editingCueID = nil
                            editingSnapshot = nil
                        } catch { errorMessage = error.localizedDescription }
                    } else {
                        editingCueID = cue.id
                        editingSnapshot = cue
                        sourceDraft = cue.sourceText
                        if case .succeeded(let text, _) = cue.translation { translationDraft = text }
                        else { translationDraft = "" }
                    }
                } label: {
                    Image(systemName: isEditing ? "checkmark.circle.fill" : "pencil")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(isEditing ? String(localized: "保存编辑", bundle: appLocalizationBundle) : String(localized: "编辑字幕", bundle: appLocalizationBundle))
                .help(isEditing ? String(localized: "保存编辑", bundle: appLocalizationBundle) : String(localized: "编辑本句", bundle: appLocalizationBundle))
                .disabled(editingCueID != nil && !isEditing)

                Button(String(localized: "重译本句", bundle: appLocalizationBundle)) {
                    do { try queue.startRetranslation(taskID: taskID, mediaID: item.id, cueIDs: [cue.id]) }
                    catch { errorMessage = error.localizedDescription }
                }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .disabled(editingCueID != nil || queue.taskID != nil)

                if isHovered {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cue.sourceText, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(String(localized: "复制原文", bundle: appLocalizationBundle))
                }
            }

            // Subtitle text lines with Apple Podcasts lyrics focus hierarchy
            VStack(alignment: .leading, spacing: 4) {
                // Source Text
                if isEditing {
                    TextField(String(localized: "原文内容", bundle: appLocalizationBundle), text: $sourceDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 16, weight: .medium))
                } else if previewMode != .translation {
                    Text(cue.sourceText)
                        .font(.system(size: isActive ? 18 : 16, weight: isActive ? .bold : .medium, design: .default))
                        .lineSpacing(3)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            playbackController.seek(toMilliseconds: cue.startMilliseconds)
                        }
                }

                // Translation Text
                if isEditing || previewMode == .translation || previewMode == .bilingual {
                    if isEditing {
                        TextField(String(localized: "译文内容", bundle: appLocalizationBundle), text: $translationDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 15))
                    } else {
                        if case .succeeded(let trans, _) = cue.translation {
                            Text(trans)
                                .font(.system(size: isActive ? 16 : 14, weight: isActive ? .semibold : .regular))
                                .foregroundStyle(.primary)
                                .lineSpacing(2)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    playbackController.seek(toMilliseconds: cue.startMilliseconds)
                                }
                        } else if case .failed(let reason) = cue.translation {
                            Text(String(localized: "翻译失败：\(reason)", bundle: appLocalizationBundle)).font(.caption).foregroundStyle(.red)
                        } else {
                            Text(String(localized: "未翻译", bundle: appLocalizationBundle))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            isActive
                ? Color.voxlineActiveCueBackground
                : (isHovered ? Color.secondary.opacity(0.06) : Color.clear),
            in: .rect(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isActive ? Color.voxlineActiveCueBorder : Color.clear, lineWidth: 1)
        )
        // Hierarchy Opacity fading: Active line = 1.0, Hovered = 0.95, Future = 0.68, Past = 0.38
        .opacity(isActive ? 1.0 : (isHovered ? 0.95 : (isPast ? 0.40 : 0.70)))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isActive)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovered)
    }

}

#endif
