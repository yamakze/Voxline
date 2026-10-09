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
    @State private var session: ProofreadingSession
    @State private var playbackController = MediaPlaybackController()
    @State private var isScrollingTranscript = false
    @State private var queue = TaskProcessingQueue.shared

    // Sheets
    @State private var showTimeOffsetSheet = false
    @State private var showSRTExportSheet = false
    @State private var showEmbeddingSheet = false
    @State private var showBurnInSheet = false
    @State private var showRelinkSheet = false
    @State private var structureState = SubtitleStructureState()

    public var onBack: (() -> Void)?

    public init(taskID: UUID, initialOutputKind: SRTOutputKind, item: TaskMediaItem, onCommit: @escaping (TaskMediaItem, TaskMediaItem) throws -> Void, onBack: (() -> Void)? = nil) {
        self.taskID = taskID
        self.initialOutputKind = initialOutputKind
        self.item = item
        self.onCommit = onCommit
        self.onBack = onBack
        _session = State(initialValue: ProofreadingSession(item: item))
    }

    public var body: some View {
        let activeCue = playbackController.activeSubtitle
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
                        catch { session.errorMessage = error.localizedDescription }
                    }
                    .disabled(queue.isCancelling)
                } else {
                    Button(String(localized: "重译字幕…", bundle: appLocalizationBundle), systemImage: "character.bubble") { session.retranslatingCues = item.cues }
                        .disabled(item.cues.isEmpty || session.editingSnapshot?.id != nil || queue.taskID != nil)
                }

                Button(String(localized: "重新关联…", bundle: appLocalizationBundle), systemImage: "link.badge.plus") {
                    showRelinkSheet = true
                }
                .disabled(queue.taskID != nil)

                Button(String(localized: "整体时间偏移…", bundle: appLocalizationBundle), systemImage: "clock") {
                    showTimeOffsetSheet = true
                }
                .disabled(item.cues.isEmpty || session.editingSnapshot?.id != nil)

                Button(String(localized: "添加字幕…", bundle: appLocalizationBundle), systemImage: "plus") {
                    structureState.insert(at: playbackController.currentTimeSeconds)
                }
                .disabled(queue.taskID != nil || session.editingSnapshot?.id != nil)
                .help(String(localized: "添加字幕", bundle: appLocalizationBundle))

                Button(String(localized: "撤销", bundle: appLocalizationBundle), systemImage: "arrow.uturn.backward") {
                    do {
                        try session.undo(in: item, onCommit: onCommit)
                    } catch {
                        session.errorMessage = error.localizedDescription
                    }
                }
                .disabled(!session.canUndo(in: item) || queue.taskID != nil)
                .keyboardShortcut("z", modifiers: [.command])
                .help(String(localized: "撤销最近一次编辑 (⌘Z)", bundle: appLocalizationBundle))

                Menu {
                    Section(String(localized: "字幕文件", bundle: appLocalizationBundle)) {
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
                .disabled(item.cues.isEmpty || session.editingSnapshot?.id != nil)
                .help(String(localized: "导出字幕或包含字幕的媒体文件", bundle: appLocalizationBundle))
            }
        }
        .alert(String(localized: "无法完成操作", bundle: appLocalizationBundle), isPresented: Binding(
            get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } }
        )) {
            Button(String(localized: "好", bundle: appLocalizationBundle), role: .cancel) { session.errorMessage = nil }
        } message: { Text(session.errorMessage ?? "") }
        .task(id: MediaPlaybackController.SourceIdentity(item: item)) {
            await playbackController.loadMedia(for: item)
        }
        .onChange(of: item.cues) { _, cues in
            session.updateSubtitles(cues)
            playbackController.updateSubtitles(cues)
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
                try updated.replaceSubtitles(shifted, comparedTo: originalCues)
                try session.saveChanges(updated, comparedTo: item, onCommit: onCommit)
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
        .subtitleStructureSheets(state: structureState, item: item, session: session, onCommit: onCommit)
        .confirmationDialog(String(localized: "重新翻译全部字幕？", bundle: appLocalizationBundle),
                            isPresented: Binding(get: { session.retranslatingCues != nil }, set: { if !$0 { session.retranslatingCues = nil } }), titleVisibility: .visible) {
            if let selected = session.retranslatingCues {
                Button(String(localized: "重新翻译", bundle: appLocalizationBundle)) {
                    do { try queue.startRetranslation(taskID: taskID, mediaID: item.id, cueIDs: selected.map(\.id)) }
                    catch { session.errorMessage = error.localizedDescription }
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
                    switch session.previewKind {
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
            ProofreadingPlayerControls(playback: playbackController, style: .capsule)
                .padding(.bottom, 16)
                .padding(.horizontal, 20)
        }
    }

    // MARK: - Apple Podcasts Lyrics/Transcript Pane
    private func podcastsTranscriptPane(activeCueID: UUID?) -> some View {
        VStack(spacing: 0) {
            // Transcript Controls Toolbar (Podcasts style)
            HStack(spacing: 12) {
                Picker(String(localized: "模式", bundle: appLocalizationBundle), selection: $session.previewKind) {
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
                    TextField(String(localized: "在字幕中搜索…", bundle: appLocalizationBundle), text: $session.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.caption)
                    if !session.searchQuery.isEmpty {
                        Button {
                            session.searchQuery = ""
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

                if session.previewKind != .source, item.cues.contains(where: { !$0.hasTranslation }) {
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
                            ForEach(session.transcriptRows) { row in
                                let cue = row.cue
                                let isActive = cue.id == activeCueID
                                let isPast = cue.endMilliseconds <= playbackController.completedSubtitleEndMilliseconds

                                ProofreadingCueRow(
                                    cue: cue,
                                    nextCue: row.nextCue,
                                    session: session,
                                    isActive: isActive,
                                    isPast: isPast,
                                    canRetranslate: true,
                                    isTaskRunning: queue.taskID != nil,
                                    onSeek: { playbackController.seek(toMilliseconds: $0) },
                                    onRetranslate: { targetCue in
                                        do { try queue.startRetranslation(taskID: taskID, mediaID: item.id, cueIDs: [targetCue.id]) }
                                        catch { session.errorMessage = error.localizedDescription }
                                    },
                                    onSaveEdit: {
                                        do { try session.saveEditing(in: item, onCommit: onCommit) }
                                        catch { session.errorMessage = error.localizedDescription }
                                    },
                                    onAdjustTiming: { targetCue in structureState.timingCue = targetCue },
                                    onSplit: { targetCue in structureState.splittingCue = targetCue },
                                    onMerge: { cues in structureState.mergingCues = cues },
                                    onDelete: { targetCue in deleteCue(targetCue) }
                                )
                                .id(cue.id)
                            }
                        }
                        .padding(.vertical, 40)
                        .padding(.horizontal, 24)
                    }
                    .onScrollPhaseChange { _, phase in
                        isScrollingTranscript = phase == .tracking || phase == .interacting || phase == .decelerating
                    }
                    .onChange(of: activeCueID) { _, newActiveID in
                        if let newActiveID, !isScrollingTranscript {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                                proxy.scrollTo(newActiveID, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }

    private func deleteCue(_ cue: SubtitleCue) {
        do {
            var updated = item
            try updated.deleteSubtitles(comparedTo: [cue])
            try session.saveChanges(updated, comparedTo: item, onCommit: onCommit)
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

}

#endif
