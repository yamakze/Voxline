#if os(iOS)
import AVKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VoxlineCore
import VoxlineMedia

struct IOSMediaDetailView: View {
    let library: IOSTaskLibrary
    let taskID: UUID
    let mediaID: UUID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isScrollingTranscript = false
    @State private var session: ProofreadingSession
    @State private var playback = MediaPlaybackController()
    @State private var importingMedia = false
    @State private var association: IOSMediaAssociationCandidate?
    @State private var showingOffset = false
    @State private var structureState = SubtitleStructureState()

    // 导出与烧录
    @State private var sharingURL: URL?
    @State private var showingEmbedding = false
    @State private var showingBurnIn = false
    @State private var importState = SubtitleImportState()

    init(library: IOSTaskLibrary, taskID: UUID, mediaID: UUID) {
        self.library = library
        self.taskID = taskID
        self.mediaID = mediaID
        let item = library.task(taskID)?.items.first { $0.id == mediaID }
        _session = State(initialValue: ProofreadingSession(
            previewKind: item?.cues.contains(where: \.hasTranslation) == true ? .bilingual : .source
        ))
    }

    private var task: ProcessingTask? { library.task(taskID) }
    private var item: TaskMediaItem? { library.task(taskID)?.items.first { $0.id == mediaID } }

    var body: some View {
        if let item {
            GeometryReader { geometry in
                let landscape = geometry.size.width > geometry.size.height
                let layout = landscape ? AnyLayout(HStackLayout(alignment: .top, spacing: 0))
                    : AnyLayout(VStackLayout(spacing: 0))

                layout {
                    // 播放器区域
                    VStack(spacing: 0) {
                        playerSection(item, height: landscape
                            ? max(120, geometry.size.height - 100)
                            : min(260, geometry.size.height * 0.42))

                        // 预览选择栏与倍速
                        previewControlBar
                    }
                    .frame(width: landscape ? geometry.size.width * 0.48 : nil)

                    // 字幕列表与多选区域
                    ZStack(alignment: .bottom) {
                        subtitlesList(item)

                        if session.isSelecting {
                            selectionActionBar(item)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                }
            }
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if session.isSelecting {
                        Button(String(localized: "完成", bundle: appLocalizationBundle)) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                session.isSelecting = false
                                session.selectedCueIDs.removeAll()
                            }
                        }
                        .bold()
                        .accessibilityLabel(String(localized: "完成选择", bundle: appLocalizationBundle))
                    } else {
                        Button {
                            guard let current = self.item else { return }
                            do {
                                try session.undo(in: current) { updated, original in
                                    try library.storage.updateItem(updated, taskID: taskID, comparedTo: original)
                                }
                            } catch {
                                session.errorMessage = error.localizedDescription
                            }
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .disabled(!session.canUndo(in: item) || library.queue.taskID != nil)
                        .accessibilityLabel(String(localized: "撤销", bundle: appLocalizationBundle))

                        mediaActionMenu(item)
                    }
                }
            }
            .fileImporter(isPresented: $importingMedia, allowedContentTypes: [
                .mpeg4Movie, .quickTimeMovie, UTType(importedAs: "com.apple.m4v-video"), .mpeg4Audio, .mp3, .wav
            ]) { result in
                switch result {
                case .success(let url): association = .init(url: url, item: item)
                case .failure(let error): session.errorMessage = error.localizedDescription
                }
            }
            .sheet(item: $association, onDismiss: { Task { if let item = self.item { await playback.loadMedia(for: item) } } }) { candidate in
                IOSMediaAssociationSheet(candidate: candidate) { updated in
                    try library.storage.updateItem(updated, taskID: taskID, comparedTo: candidate.item)
                }
            }
            .sheet(item: $session.editingSnapshot) { cue in
                IOSSubtitleEditor(session: session) {
                    guard let current = self.item else { throw TaskValidationError.taskChanged }
                    try session.saveEditing(in: current) { updated, original in
                        try library.storage.updateItem(updated, taskID: taskID, comparedTo: original)
                    }
                }
            }
            .sheet(isPresented: $showingOffset) {
                IOSSubtitleOffsetEditor { milliseconds in
                    guard var updated = self.item else { throw TaskValidationError.taskChanged }
                    let original = updated
                    let shifted = try SubtitleTimeOffset.shifted(updated.cues, by: milliseconds,
                                                                 withinDuration: updated.media?.durationMilliseconds)
                    try updated.replaceSubtitles(shifted, comparedTo: original.cues)
                    try session.saveChanges(updated, comparedTo: original) { updated, original in
                        try library.storage.updateItem(updated, taskID: taskID, comparedTo: original)
                    }
                }
            }
            .sheet(isPresented: $showingEmbedding) {
                IOSSubtitleEmbeddingSheet(item: item, task: task)
            }
            .sheet(isPresented: $showingBurnIn) {
                IOSSubtitleBurnInSheet(item: item)
            }
            .sheet(item: Binding(get: { sharingURL.map { SharePayload(url: $0) } }, set: { sharingURL = $0?.url })) { payload in
                ShareActivitySheet(activityItems: [payload.url])
            }
            .subtitleStructureSheets(state: structureState, item: item, session: session, onCommit: { updated, original in
                try library.storage.updateItem(updated, taskID: taskID, comparedTo: original)
                session.selectedCueIDs.removeAll()
                session.isSelecting = false
            })
            .confirmationDialog(String(localized: "重新翻译所选字幕？", bundle: appLocalizationBundle),
                                isPresented: Binding(get: { session.retranslatingCues != nil }, set: { if !$0 { session.retranslatingCues = nil } }), titleVisibility: .visible) {
                if let selected = session.retranslatingCues {
                    Button(String(localized: "重新翻译", bundle: appLocalizationBundle)) {
                        do {
                            try library.queue.startRetranslation(taskID: taskID, mediaID: mediaID, cueIDs: selected.map(\.id))
                            session.isSelecting = false
                            session.selectedCueIDs.removeAll()
                        } catch { session.errorMessage = error.localizedDescription }
                    }
                }
                Button(String(localized: "取消", bundle: appLocalizationBundle), role: .cancel) {}
            }

            .subtitleImportSheets(state: importState, item: item, taskID: taskID,
                library: library.storage, session: session, onCommit: { updated, original in
                    try library.storage.updateItem(updated, taskID: taskID, comparedTo: original)
                })
            .alert(String(localized: "操作异常", bundle: appLocalizationBundle), isPresented: Binding(
                get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
                Button(String(localized: "好", bundle: appLocalizationBundle)) { session.errorMessage = nil }
            } message: { Text(session.errorMessage ?? "") }
            .task(id: MediaPlaybackController.SourceIdentity(item: item)) { await playback.loadMedia(for: item) }
            .onChange(of: item.cues) { _, cues in
                session.updateSubtitles(cues)
                playback.updateSubtitles(cues)
            }
            .onAppear { session.updateSubtitles(item.cues) }
            .onDisappear { playback.releaseMedia() }
        } else {
            ContentUnavailableView(String(localized: "媒体不存在", bundle: appLocalizationBundle), systemImage: "film")
        }
    }

    // MARK: - 播放器区域
    @ViewBuilder
    private func playerSection(_ item: TaskMediaItem, height: CGFloat) -> some View {
        if let player = playback.player {
            ZStack(alignment: .bottom) {
                if item.kind == .video {
                    VideoPlayer(player: player)
                        .frame(height: height)
                } else {
                    ZStack {
                        LinearGradient(colors: [Color.purple.opacity(0.18), Color.purple.opacity(0.06)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        VStack(spacing: 8) {
                            Image(systemName: "waveform")
                                .font(.system(size: 32))
                                .foregroundStyle(.purple)
                            Text(item.title)
                                .font(.headline)
                                .lineLimit(1)
                            if let media = item.media {
                                Text(String(localized: "音轨 \(media.audioTrackID) · \(formatDuration(media.durationMilliseconds))", bundle: appLocalizationBundle))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                    }
                    .frame(height: min(150, height))
                }

                // 悬浮字幕预览（支持重叠字幕同时展示）
                if !playback.activeSubtitles.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(playback.activeSubtitles) { cue in
                            VStack(spacing: 2) {
                                if session.previewKind != .translation {
                                    Text(cue.sourceText)
                                        .font(.subheadline.weight(.medium))
                                }
                                if session.previewKind != .source {
                                    if case .succeeded(let text, _) = cue.translation, cue.hasTranslation {
                                        Text(text)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text(String(localized: "待更新", bundle: appLocalizationBundle))
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .liquidGlassSurface(cornerRadius: 10)
                    .padding(.horizontal, 16)
                    .padding(.bottom, item.kind == .video ? 16 : 8)
                    .allowsHitTesting(false)
                }
            }

            // 精致播放控制卡片
            ProofreadingPlayerControls(playback: playback, style: .card)
        } else if playback.isLoading {
            ProgressView(String(localized: "读取本地媒体…", bundle: appLocalizationBundle))
                .frame(maxWidth: .infinity, minHeight: 140)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "film.stack")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(playback.errorMessage ?? String(localized: "媒体尚未关联", bundle: appLocalizationBundle))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button(String(localized: "关联本地媒体", bundle: appLocalizationBundle)) {
                    importingMedia = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding()
            .frame(maxWidth: .infinity, minHeight: 140)
            .background(Color.secondary.opacity(0.04))
        }
    }

    // MARK: - 预览与倍速切换栏
    private var previewControlBar: some View {
        HStack(spacing: 12) {
            Picker(String(localized: "字幕预览", bundle: appLocalizationBundle), selection: $session.previewKind) {
                Text(String(localized: "原文", bundle: appLocalizationBundle)).tag(SRTOutputKind.source)
                Text(String(localized: "译文", bundle: appLocalizationBundle)).tag(SRTOutputKind.translation)
                Text(String(localized: "双语", bundle: appLocalizationBundle)).tag(SRTOutputKind.bilingual)
            }
            .pickerStyle(.segmented)

            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                    Button("\(speed, specifier: "%.2g")x") {
                        playback.setRate(Float(speed))
                    }
                }
            } label: {
                Text("\(playback.playbackRate, specifier: "%.2g")x")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - 字幕列表区域
    @ViewBuilder
    private func subtitlesList(_ item: TaskMediaItem) -> some View {
        ScrollViewReader { proxy in
            List {
                // 处理状态栏
                if library.queue.taskID == taskID && library.queue.mediaID == mediaID {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(library.queue.progressText ?? String(localized: "正在处理…", bundle: appLocalizationBundle))
                            .font(.caption)
                        Spacer()
                        Button(library.queue.isCancelling ? String(localized: "取消中", bundle: appLocalizationBundle) : String(localized: "取消", bundle: appLocalizationBundle)) {
                            do { try library.queue.cancel(mediaID: mediaID) }
                            catch { session.errorMessage = error.localizedDescription }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(library.queue.isCancelling)
                    }
                    .padding(.vertical, 2)
                    .listRowBackground(Color.blue.opacity(0.08))
                }

                if item.cues.isEmpty {
                    VStack(spacing: 12) {
                        ContentUnavailableView(String(localized: "暂无字幕内容", bundle: appLocalizationBundle), systemImage: "character.bubble")
                        Button(String(localized: "导入原文字幕…", bundle: appLocalizationBundle)) {
                            importState.presentation = .original
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(library.queue.taskID != nil || item.media == nil)
                    }
                    .padding(.vertical, 30)
                }

                let activeIDs = Set(playback.activeSubtitles.map(\.id))
                ForEach(session.transcriptRows) { row in
                    let cue = row.cue
                    ProofreadingCueRow(
                        cue: cue,
                        nextCue: row.nextCue,
                        session: session,
                        isActive: activeIDs.contains(cue.id),
                        canRetranslate: task?.parameters.translation != nil,
                        isTaskRunning: library.queue.taskID != nil,
                        onSeek: { playback.seek(toMilliseconds: $0) },
                        onRetranslate: { targetCue in
                            do { try library.queue.startRetranslation(taskID: taskID, mediaID: mediaID, cueIDs: [targetCue.id]) }
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
            .listStyle(.plain)
            .onScrollPhaseChange { _, phase in
                isScrollingTranscript = phase == .tracking || phase == .interacting || phase == .decelerating
            }
            .onChange(of: playback.activeSubtitle?.id) { _, newID in
                if let newID, playback.isPlaying, !isScrollingTranscript {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - 多选悬浮操作栏
    @ViewBuilder
    private func selectionActionBar(_ item: TaskMediaItem) -> some View {
        HStack(spacing: 12) {
            Button(session.selectedCueIDs.count == item.cues.count ? String(localized: "取消全选", bundle: appLocalizationBundle) : String(localized: "全选", bundle: appLocalizationBundle)) {
                if session.selectedCueIDs.count == item.cues.count {
                    session.selectedCueIDs.removeAll()
                } else {
                    session.selectedCueIDs = Set(item.cues.map(\.id))
                }
            }
            .font(.subheadline)

            Text(String(localized: "已选 \(session.selectedCueIDs.count) 句", bundle: appLocalizationBundle))
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Spacer()

            if let adjacent = selectedAdjacentCues(in: item) {
                Button {
                    structureState.mergingCues = adjacent
                } label: {
                    Label(String(localized: "合并", bundle: appLocalizationBundle), systemImage: "arrow.triangle.merge")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(library.queue.taskID != nil)
            }

            if task?.parameters.translation != nil {
                Button {
                    let targets = item.cues.filter { session.selectedCueIDs.contains($0.id) }
                    session.retranslatingCues = targets
                } label: {
                    Label(String(localized: "重译", bundle: appLocalizationBundle), systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(session.selectedCueIDs.isEmpty || library.queue.taskID != nil)
            }

            Button(role: .destructive) {
                deleteSelectedCues(in: item)
            } label: {
                Image(systemName: "trash")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
            .disabled(session.selectedCueIDs.isEmpty || library.queue.taskID != nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .liquidGlassSurface(cornerRadius: 14)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    // MARK: - 媒体操作菜单
    @ViewBuilder
    private func mediaActionMenu(_ item: TaskMediaItem) -> some View {
        Menu {
            Button(String(localized: "添加字幕…", bundle: appLocalizationBundle), systemImage: "plus") {
                structureState.insert(at: playback.currentTimeSeconds)
            }
            .disabled(library.queue.taskID != nil)

            if !item.cues.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        session.isSelecting = true
                    }
                } label: {
                    Label(String(localized: "选择字幕…", bundle: appLocalizationBundle), systemImage: "checkmark.circle")
                }
                .disabled(library.queue.taskID != nil)
            }

            Divider()

            SubtitleImportActions(state: importState, item: item,
                isDisabled: library.queue.taskID != nil || session.editingSnapshot != nil)

            Divider()

            // 导出与分享子菜单
            Menu {
                Button {
                    shareSRT(kind: .source, item: item)
                } label: {
                    Label(String(localized: "导出原文字幕 (.srt)", bundle: appLocalizationBundle), systemImage: "doc.text")
                }
                .disabled(item.cues.isEmpty)

                Button {
                    shareSRT(kind: .translation, item: item)
                } label: {
                    Label(String(localized: "导出译文字幕 (.srt)", bundle: appLocalizationBundle), systemImage: "doc.text.fill")
                }
                .disabled(item.cues.isEmpty)

                Button {
                    shareSRT(kind: .bilingual, item: item)
                } label: {
                    Label(String(localized: "导出双语字幕 (.srt)", bundle: appLocalizationBundle), systemImage: "doc.on.doc")
                }
                .disabled(item.cues.isEmpty)

                if item.kind == .video {
                    Divider()
                    Button {
                        showingEmbedding = true
                    } label: {
                        Label(String(localized: "内封软字幕视频 (.mp4)…", bundle: appLocalizationBundle), systemImage: "captions.bubble")
                    }
                    .disabled(item.cues.isEmpty)

                    Button {
                        showingBurnIn = true
                    } label: {
                        Label(String(localized: "烧录字幕视频 (.mp4)…", bundle: appLocalizationBundle), systemImage: "film")
                    }
                    .disabled(item.cues.isEmpty)
                }
            } label: {
                Label(String(localized: "导出与分享", bundle: appLocalizationBundle), systemImage: "square.and.arrow.up")
            }

            Divider()

            let hasTranslation = task?.parameters.translation != nil
            if hasTranslation {
                if session.hasUntranslatedCues {
                    Button(String(localized: "继续翻译", bundle: appLocalizationBundle), systemImage: "character.bubble") {
                        do { try library.startTranslation(taskID: taskID, mediaID: mediaID) }
                        catch { session.errorMessage = error.localizedDescription }
                    }
                    .disabled(library.queue.taskID != nil || !item.hasSourceSubtitles)
                }

                if !item.cues.isEmpty {
                    Button(String(localized: "重译全部字幕…", bundle: appLocalizationBundle), systemImage: "arrow.triangle.2.circlepath") {
                        session.retranslatingCues = item.cues
                    }
                    .disabled(library.queue.taskID != nil)
                }
            }

            Divider()

            Button(String(localized: "重新关联媒体…", bundle: appLocalizationBundle), systemImage: "paperclip") {
                importingMedia = true
            }

            Button(String(localized: "整体时间偏移…", bundle: appLocalizationBundle), systemImage: "clock") {
                showingOffset = true
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(String(localized: "媒体操作", bundle: appLocalizationBundle))
    }

    private func selectedAdjacentCues(in item: TaskMediaItem) -> [SubtitleCue]? {
        guard session.selectedCueIDs.count >= 2 else { return nil }
        let indexedCues = item.cues.enumerated().filter { session.selectedCueIDs.contains($0.element.id) }
        guard indexedCues.count == session.selectedCueIDs.count else { return nil }
        let indices = indexedCues.map(\.offset)
        guard let first = indices.first, let last = indices.last else { return nil }
        guard last - first + 1 == indices.count else { return nil }
        return indexedCues.map(\.element)
    }

    private func deleteCue(_ cue: SubtitleCue) {
        guard let current = self.item else { return }
        do {
            var updated = current
            try updated.deleteSubtitles(comparedTo: [cue])
            try session.saveChanges(updated, comparedTo: current) { updated, original in
                try library.storage.updateItem(updated, taskID: taskID, comparedTo: original)
            }
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    private func deleteSelectedCues(in item: TaskMediaItem) {
        let targets = item.cues.filter { session.selectedCueIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        do {
            var updated = item
            try updated.deleteSubtitles(comparedTo: targets)
            try session.saveChanges(updated, comparedTo: item) { updated, original in
                try library.storage.updateItem(updated, taskID: taskID, comparedTo: original)
            }
            session.selectedCueIDs.removeAll()
            session.isSelecting = false
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    private func shareSRT(kind: SRTOutputKind, item: TaskMediaItem) {
        do {
            let url = try IOSExportHelper.prepareSRT(for: item, kind: kind)
            sharingURL = url
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    private func formatTime(_ milliseconds: Int64) -> String {
        Duration.milliseconds(milliseconds).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2, fractionalSecondsLength: 3)))
    }

    private func formatDuration(_ milliseconds: Int64) -> String {
        String(format: "%.1fs", Double(milliseconds) / 1000.0)
    }
}

private struct SharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

private struct IOSSubtitleEditor: View {
    @Bindable var session: ProofreadingSession
    let onSave: () throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "原文", bundle: appLocalizationBundle)) {
                    TextEditor(text: $session.sourceDraft)
                        .frame(minHeight: 100)
                }
                Section(String(localized: "译文", bundle: appLocalizationBundle)) {
                    TextEditor(text: $session.translationDraft)
                        .frame(minHeight: 100)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(String(localized: "编辑字幕", bundle: appLocalizationBundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消", bundle: appLocalizationBundle)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "保存", bundle: appLocalizationBundle)) {
                        do {
                            try onSave()
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
    }
}

private struct IOSSubtitleOffsetEditor: View {
    let onSave: (Int64) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var secondsText = "0"
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "偏移秒数", bundle: appLocalizationBundle), text: $secondsText)
                        .keyboardType(.numbersAndPunctuation)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(String(localized: "整体时间偏移", bundle: appLocalizationBundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消", bundle: appLocalizationBundle)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "应用", bundle: appLocalizationBundle)) {
                        do {
                            guard let seconds = Double(secondsText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                                throw SubtitleTimeOffsetError.invalidOffset
                            }
                            try onSave(SubtitleTimeOffset.milliseconds(from: seconds))
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
    }
}
#endif
