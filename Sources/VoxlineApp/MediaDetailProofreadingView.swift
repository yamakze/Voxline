import SwiftUI
import AVKit
import Observation
import VoxlineCore
import VoxlineMedia

public struct MediaDetailProofreadingView: View {
    @Binding var item: TaskMediaItem
    @State private var playbackController = MediaPlaybackController()
    @State private var previewMode: SRTOutputKind = .bilingual
    @State private var searchQuery: String = ""
    @State private var hoveredCueID: UUID?
    @State private var errorMessage: String?
    @State private var editingCueID: UUID?

    // Sheets
    @State private var showTimeOffsetSheet = false
    @State private var showSRTExportSheet = false
    @State private var showRelinkSheet = false

    public init(item: Binding<TaskMediaItem>) {
        _item = item
        let hasTranslation = item.wrappedValue.cues.contains { cue in
            if case .succeeded = cue.translation { return true }
            return false
        }
        _previewMode = State(initialValue: hasTranslation ? .bilingual : .source)
    }

    private var activeCueID: UUID? {
        playbackController.activeCue(in: item.cues)?.id
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
        VStack(spacing: 0) {
            // Top Bar
            topBar

            Divider()

            // Main Split: QuickTime Video Player on Left + Apple Podcasts Lyrics/Transcript on Right
            HSplitView {
                // Left Column: QuickTime Player with Floating Glass Capsule Controls
                quickTimePlayerPane
                    .frame(minWidth: 440, idealWidth: 540)

                // Right Column: Apple Podcasts Lyrics/Transcript Stream
                podcastsTranscriptPane
                    .frame(minWidth: 460, idealWidth: 580)
            }
        }
        .alert("无法完成操作", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .task(id: item.id) {
            await playbackController.loadMedia(for: item)
        }
        .onDisappear {
            playbackController.releaseMedia()
        }
        .sheet(isPresented: $showTimeOffsetSheet) {
            TimeOffsetSheet(
                cues: $item.cues,
                mediaDurationMilliseconds: item.media?.durationMilliseconds
            )
        }
        .sheet(isPresented: $showSRTExportSheet) {
            SRTExportSheet(
                mediaTitle: item.title,
                cues: item.cues
            )
        }
        .sheet(isPresented: $showRelinkSheet, onDismiss: {
            Task { await playbackController.loadMedia(for: item) }
        }) {
            MediaRelinkSheet(item: $item)
        }

    }

    // MARK: - Top Bar
    private var topBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    TextField("媒体标题", text: $item.title)
                        .font(.headline)
                        .textFieldStyle(.plain)

                    MediaStatusBadge(status: item.status)
                }

                HStack(spacing: 10) {
                    Label(item.kind == .video ? "视频" : "音频", systemImage: item.kind == .video ? "film" : "waveform")
                    if let media = item.media {
                        Text(media.fileName).lineLimit(1).truncationMode(.middle)
                        Text(String(format: "%.1fs", Double(media.durationMilliseconds) / 1000.0))
                        Text("轨 \(media.audioTrackID)")
                    } else {
                        Text("未关联源文件").foregroundStyle(.red)
                    }
                    Text("\(item.cues.count) 句字幕")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Header actions
            HStack(spacing: 8) {
                if item.media == nil || playbackController.isMediaUnavailable {
                    Button("重新关联", systemImage: "link.badge.plus") {
                        showRelinkSheet = true
                    }
                    .buttonStyle(.bordered)
                }

                Button("整体偏移行…", systemImage: "timer") {
                    showTimeOffsetSheet = true
                }
                .buttonStyle(.bordered)
                .disabled(item.cues.isEmpty)

                Button("导出 SRT…", systemImage: "square.and.arrow.up") {
                    showSRTExportSheet = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(item.cues.isEmpty)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    // MARK: - QuickTime Player Pane (with Floating Glass Capsule)
    private var quickTimePlayerPane: some View {
        ZStack(alignment: .bottom) {
            // Video or Audio Canvas
            Group {
                if let player = playbackController.player, playbackController.isReady {
                    if item.kind == .video {
                        VideoPlayer(player: player)
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
                                Text("本地原生音频 · 逐句同步")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    // Demo / Fallback canvas
                    ZStack {
                        Color.black.opacity(0.9)
                        VStack(spacing: 12) {
                            if playbackController.isLoading {
                                ProgressView("正在加载媒体…")
                                    .foregroundStyle(.white)
                            } else {
                                Image(systemName: item.kind == .video ? "video.badge.plus" : "waveform.badge.plus")
                                    .font(.system(size: 48))
                                    .foregroundStyle(.white.opacity(0.6))
                                Text("媒体待关联或本地原文件未找到")
                                    .font(.headline).foregroundStyle(.white)
                                Text(playbackController.errorMessage ?? "请点击重新关联指定本地原文件。")
                                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 24)

                                Button("关联本地媒体", systemImage: "link") {
                                    showRelinkSheet = true
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            // Active Subtitle HUD Overlay (QuickTime cinema subtitle overlay)
            if let activeCue = playbackController.activeCue(in: item.cues) {
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
                            Text(activeCue.sourceText)
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                    case .bilingual:
                        Text(activeCue.sourceText)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                        if case .succeeded(let trans, _) = activeCue.translation {
                            Text(trans)
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(.yellow)
                        }
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .subtitleOverlaySurface()
                .padding(.bottom, 78) // Positioned above floating capsule
                .padding(.horizontal, 24)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.15), value: activeCue.id)
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
            .frame(minWidth: 100)

            Text(playbackController.formattedDuration)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)

            // Speed Menu
            Menu {
                Button("0.5x") { playbackController.setRate(0.5) }
                Button("0.75x") { playbackController.setRate(0.75) }
                Button("1.0x (正常)") { playbackController.setRate(1.0) }
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
    }

    // MARK: - Apple Podcasts Lyrics/Transcript Pane
    private var podcastsTranscriptPane: some View {
        VStack(spacing: 0) {
            // Transcript Controls Toolbar (Podcasts style)
            HStack(spacing: 12) {
                Picker("模式", selection: $previewMode) {
                    Text("原文").tag(SRTOutputKind.source)
                    Text("译文").tag(SRTOutputKind.translation)
                    Text("双语").tag(SRTOutputKind.bilingual)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("在字幕中搜索…", text: $searchQuery)
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

                if previewMode != .source, item.cues.contains(where: { !$0.hasCurrentTranslation }) {
                    Text("API 翻译尚未接通")
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
                    "暂无逐句字幕",
                    systemImage: "quote.bubble",
                    description: Text("当前媒体条目尚未转写生成字幕。")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(filteredCues) { cue in
                                let isActive = cue.id == activeCueID
                                let isHovered = cue.id == hoveredCueID
                                let isEditing = cue.id == editingCueID
                                let isPast = cue.endMilliseconds < Int64(playbackController.currentTimeSeconds * 1000.0)

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
        if let cueIndex = item.cues.firstIndex(where: { $0.id == cue.id }) {
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

                    // Status chip
                    if case .succeeded = cue.translation, !cue.hasCurrentTranslation {
                        Text("待重译")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2), in: .capsule)
                            .foregroundStyle(.orange)
                    }

                    Spacer()

                    // Hover Actions
                    if isHovered {
                        HStack(spacing: 8) {
                            Button {
                                editingCueID = (editingCueID == cue.id) ? nil : cue.id
                            } label: {
                                Image(systemName: isEditing ? "checkmark.circle.fill" : "pencil")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help(isEditing ? "完成编辑" : "直接编辑本句")

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(cue.sourceText, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("复制原文")
                        }
                        .transition(.opacity)
                    }
                }

                // Subtitle text lines with Apple Podcasts lyrics focus hierarchy
                VStack(alignment: .leading, spacing: 4) {
                    // Source Text
                    if isEditing {
                        TextField("原文内容", text: Binding(
                            get: { item.cues[cueIndex].sourceText },
                            set: { newText in
                                do { try item.cues[cueIndex].replaceSourceText(with: newText) }
                                catch { errorMessage = error.localizedDescription }
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 16, weight: .medium))
                    } else {
                        Text(cue.sourceText)
                            .font(.system(size: isActive ? 18 : 16, weight: isActive ? .bold : .medium, design: .default))
                            .lineSpacing(3)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                playbackController.seek(toMilliseconds: cue.startMilliseconds)
                            }
                    }

                    // Translation Text
                    if previewMode == .translation || previewMode == .bilingual {
                        if isEditing {
                            TextField("译文内容", text: Binding(
                                get: {
                                    if case .succeeded(let trans, _) = item.cues[cueIndex].translation {
                                        return trans
                                    }
                                    return ""
                                },
                                set: { newTrans in
                                    item.cues[cueIndex].translation = .succeeded(text: newTrans, sourceRevision: cue.sourceRevision)
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 15))
                        } else {
                            if case .succeeded(let trans, _) = cue.translation {
                                Text(trans)
                                    .font(.system(size: isActive ? 16 : 14, weight: isActive ? .semibold : .regular))
                                    .foregroundStyle(isActive ? .yellow : .primary)
                                    .lineSpacing(2)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        playbackController.seek(toMilliseconds: cue.startMilliseconds)
                                    }
                            } else if case .failed(let reason) = cue.translation {
                                Text("翻译失败：\(reason)").font(.caption).foregroundStyle(.red)
                            } else {
                                Text("未翻译")
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
            .animation(.easeInOut(duration: 0.2), value: isActive)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
    }

}
