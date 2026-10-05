#if os(iOS)
import SwiftUI
import AVKit
import UniformTypeIdentifiers
import VoxlineCore
import VoxlineMedia

struct IOSMediaDetailView: View {
    let library: IOSTaskLibrary
    let taskID: UUID
    let mediaID: UUID
    @State private var playback = MediaPlaybackController()
    @State private var importingMedia = false
    @State private var association: IOSMediaAssociationCandidate?
    @State private var editingCue: SubtitleCue?
    @State private var showingOffset = false
    @State private var errorMessage: String?
    @State private var previewKind: SRTOutputKind = .bilingual

    @State private var retranslatingCues: [SubtitleCue]?
    @State private var editingParameters = false

    private var task: ProcessingTask? { library.task(taskID) }
    private var item: TaskMediaItem? { library.task(taskID)?.items.first { $0.id == mediaID } }

    var body: some View {
        if let item {
            let activeCue = playback.activeCue(in: item.cues)
            GeometryReader { geometry in
                let landscape = geometry.size.width > geometry.size.height
                let layout = landscape ? AnyLayout(HStackLayout(alignment: .top, spacing: 0))
                    : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    VStack(spacing: 0) {
                        player(item, activeCue: activeCue, height: landscape ? max(80, geometry.size.height - 110)
                            : min(240, geometry.size.height * 0.45))
                        Picker("字幕预览", selection: $previewKind) {
                            Text("原文").tag(SRTOutputKind.source)
                            Text("译文").tag(SRTOutputKind.translation)
                            Text("双语").tag(SRTOutputKind.bilingual)
                        }
                        .pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
                    }
                    .frame(width: landscape ? geometry.size.width * 0.5 : nil)
                    List {
                        // Translation progress banner
                        if library.queue.taskID == taskID && library.queue.mediaID == mediaID {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text(library.queue.progressText ?? "正在翻译…").font(.caption)
                                Spacer()
                                Button(library.queue.isCancelling ? "取消中" : "取消") {
                                    do { try library.queue.cancel() }
                                    catch { errorMessage = error.localizedDescription }
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(library.queue.isCancelling)
                            }
                            .padding(.vertical, 4)
                        } else if let error = library.queue.errorMessage {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                            .padding(.vertical, 4)
                        }

                        if item.cues.isEmpty {
                            ContentUnavailableView("无字幕内容", systemImage: "character.bubble")
                                .padding(.vertical, 40)
                        }

                        ForEach(item.cues) { cue in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Button(time(cue.startMilliseconds)) { playback.seek(toMilliseconds: cue.startMilliseconds) }
                                        .font(.caption.monospacedDigit()).disabled(!playback.isReady)
                                    Text("→ \(time(cue.endMilliseconds))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Spacer()

                                    if task?.parameters.translation != nil {
                                        Button {
                                            retranslatingCues = [cue]
                                        } label: {
                                            Image(systemName: "arrow.triangle.2.circlepath")
                                                .foregroundStyle(.tint)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(library.queue.taskID != nil)
                                    }

                                    Button {
                                        editingCue = cue
                                    } label: {
                                        Image(systemName: "pencil")
                                    }
                                    .buttonStyle(.plain)
                                }
                                Text(cue.sourceText).textSelection(.enabled)
                                switch cue.translation {
                                case .succeeded(let text, _):
                                    Text(text).foregroundStyle(.secondary).textSelection(.enabled)
                                    if !cue.hasCurrentTranslation {
                                        Label("原文已修改，译文待更新", systemImage: "exclamationmark.circle")
                                            .font(.caption).foregroundStyle(.orange)
                                    }
                                case .failed(let reason): Text(reason).font(.caption).foregroundStyle(.red)
                                case .pending: Text("待翻译").font(.caption).foregroundStyle(.secondary)
                                }
                                if cue.requiresTimingReview == true {
                                    Button("确认校对") {
                                        do {
                                            var updated = item
                                            try updated.confirmTimingReview(cueID: cue.id)
                                            try library.storage.updateItem(updated, taskID: taskID, comparedTo: item)
                                        } catch { errorMessage = error.localizedDescription }
                                    }
                                }
                            }
                            .padding(.vertical, 6)
                            .listRowBackground(activeCue?.id == cue.id ? Color.primary.opacity(0.08) : nil)
                            .buttonStyle(.borderless)
                            .contextMenu {
                                if task?.parameters.translation != nil {
                                    Button("重译此句", systemImage: "arrow.triangle.2.circlepath") {
                                        retranslatingCues = [cue]
                                    }
                                    .disabled(library.queue.taskID != nil)
                                }
                                Button("编辑字幕", systemImage: "pencil") {
                                    editingCue = cue
                                }
                                if cue.requiresTimingReview == true {
                                    Button("确认校对", systemImage: "checkmark.circle") {
                                        do {
                                            var updated = item
                                            try updated.confirmTimingReview(cueID: cue.id)
                                            try library.storage.updateItem(updated, taskID: taskID, comparedTo: item)
                                        } catch { errorMessage = error.localizedDescription }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu("媒体操作", systemImage: "ellipsis") {
                        let hasTranslation = task?.parameters.translation != nil
                        if hasTranslation {
                            if !item.cues.isEmpty && !item.cues.allSatisfy(\.hasCurrentTranslation) {
                                Button("继续翻译", systemImage: "character.bubble") {
                                    do { try library.startTranslation(taskID: taskID, mediaID: mediaID) }
                                    catch { errorMessage = error.localizedDescription }
                                }
                                .disabled(library.queue.taskID != nil)
                            }

                            if !item.cues.isEmpty {
                                Button("重译全部字幕…", systemImage: "arrow.triangle.2.circlepath") {
                                    retranslatingCues = item.cues
                                }
                                .disabled(library.queue.taskID != nil)
                            }
                        } else {
                            Button("配置翻译服务…", systemImage: "slider.horizontal.3") {
                                editingParameters = true
                            }
                            .disabled(library.queue.taskID == taskID)
                        }

                        Button("关联媒体", systemImage: "paperclip") { importingMedia = true }
                        Button("整体时间偏移", systemImage: "clock") { showingOffset = true }
                    }
                }
            }
            .fileImporter(isPresented: $importingMedia, allowedContentTypes: [
                .mpeg4Movie, .quickTimeMovie, UTType(importedAs: "com.apple.m4v-video"), .mpeg4Audio, .mp3, .wav
            ]) { result in
                switch result {
                case .success(let url): association = .init(url: url, item: item)
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            .sheet(item: $association, onDismiss: { Task { if let item = self.item { await playback.loadMedia(for: item) } } }) { candidate in
                IOSMediaAssociationSheet(candidate: candidate) { updated in
                    try library.storage.updateItem(updated, taskID: taskID, comparedTo: candidate.item)
                }
            }
            .sheet(item: $editingCue) { cue in
                IOSSubtitleEditor(cue: cue) { source, translation in
                    guard var updated = self.item else { throw TaskValidationError.taskChanged }
                    let original = updated
                    try updated.editSubtitle(comparedTo: cue, sourceText: source, translationText: translation)
                    try library.storage.updateItem(updated, taskID: taskID, comparedTo: original)
                }
            }
            .sheet(isPresented: $showingOffset) {
                IOSSubtitleOffsetEditor { milliseconds in
                    guard var updated = self.item else { throw TaskValidationError.taskChanged }
                    let original = updated
                    updated.cues = try SubtitleTimeOffset.shifted(updated.cues, by: milliseconds,
                                                                 withinDuration: updated.media?.durationMilliseconds)
                    try library.storage.updateItem(updated, taskID: taskID, comparedTo: original)
                }
            }
            .sheet(isPresented: Binding(get: { retranslatingCues != nil }, set: { if !$0 { retranslatingCues = nil } })) {
                if let selected = retranslatingCues {
                    RetranslateConfirmationSheet(affectedCues: selected) { replaceExisting in
                        let ids = selected.filter { cue in
                            if case .succeeded = cue.translation { return replaceExisting }
                            return true
                        }.map(\.id)
                        guard !ids.isEmpty else { return }
                        do {
                            try library.queue.startRetranslation(
                                taskID: taskID,
                                mediaID: mediaID,
                                cueIDs: ids,
                                replacingExistingTranslations: replaceExisting
                            )
                        } catch { errorMessage = error.localizedDescription }
                    }
                }
            }
            .sheet(isPresented: $editingParameters) {
                if let currentTask = task {
                    TaskTranslationParametersView(task: currentTask) { updated, original in
                        guard library.task(taskID) == original else { throw TaskValidationError.taskChanged }
                        try library.save(updated)
                    }
                }
            }
            .alert("操作未完成", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .task(id: mediaID) { await playback.loadMedia(for: item) }
            .onDisappear { playback.releaseMedia() }
        } else { ContentUnavailableView("媒体不存在", systemImage: "film") }
    }

    @ViewBuilder private func player(_ item: TaskMediaItem, activeCue: SubtitleCue?, height: CGFloat) -> some View {
        if let player = playback.player {
            ZStack(alignment: .bottom) {
                if item.kind == .video {
                    VideoPlayer(player: player).frame(height: height)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.purple.opacity(0.12))
                        VStack(spacing: 8) {
                            Image(systemName: "waveform")
                                .font(.system(size: 36))
                                .foregroundStyle(.purple)
                            Text(item.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            if let media = item.media {
                                Text("音轨 \(media.audioTrackID) · \(String(format: "%.1fs", Double(media.durationMilliseconds) / 1000.0))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                    }
                    .frame(height: min(150, height))
                }

                if let cue = activeCue {
                    VStack(spacing: 4) {
                        if previewKind != .translation { Text(cue.sourceText) }
                        if previewKind != .source {
                            if case .succeeded(let text, _) = cue.translation, cue.hasCurrentTranslation { Text(text) }
                            else { Text("译文待更新") }
                        }
                    }
                    .font(.callout).multilineTextAlignment(.center)
                    .padding(8).liquidGlassSurface(cornerRadius: 10)
                    .padding(.horizontal, 12).padding(.bottom, item.kind == .video ? 20 : 10).allowsHitTesting(false)
                }
            }

            // Controls with Progress Slider and Time
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text(playback.formattedCurrentTime)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Slider(
                        value: Binding(
                            get: { playback.currentTimeSeconds },
                            set: { playback.seek(to: $0) }
                        ),
                        in: 0...max(playback.durationSeconds, 0.1)
                    )
                    .disabled(!playback.isReady)

                    Text(playback.formattedDuration)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)

                HStack(spacing: 24) {
                    Spacer()
                    Button("后退 5 秒", systemImage: "gobackward.5") { playback.seekRelative(by: -5) }
                    Button(playback.isPlaying ? "暂停" : "播放", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
                        playback.togglePlayPause()
                    }
                    Button("前进 5 秒", systemImage: "goforward.5") { playback.seekRelative(by: 5) }
                    Spacer()
                }
                .labelStyle(.iconOnly)
                .font(.headline)
            }
            .padding(.vertical, 6)
            .background(Color.voxlineControlBackground)
            .disabled(!playback.isReady)
        } else if playback.isLoading {
            ProgressView("读取本地媒体…").frame(height: 160)
        } else {
            VStack(spacing: 8) {
                Text(playback.errorMessage ?? "媒体尚未关联").font(.callout).foregroundStyle(.secondary)
                Button("关联本地媒体", systemImage: "paperclip") { importingMedia = true }.buttonStyle(.bordered)
            }
            .padding().frame(maxWidth: .infinity, minHeight: 140)
        }
    }

    private func time(_ milliseconds: Int64) -> String {
        Duration.milliseconds(milliseconds).formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 2, fractionalSecondsLength: 3)))
    }
}

private struct IOSSubtitleEditor: View {
    let cue: SubtitleCue
    let onSave: (String, String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var source: String
    @State private var translation: String
    @State private var errorMessage: String?

    init(cue: SubtitleCue, onSave: @escaping (String, String) throws -> Void) {
        self.cue = cue
        self.onSave = onSave
        _source = State(initialValue: cue.sourceText)
        if case .succeeded(let text, _) = cue.translation { _translation = State(initialValue: text) }
        else { _translation = State(initialValue: "") }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("原文") { TextEditor(text: $source).frame(minHeight: 110).accessibilityLabel("原文") }
                Section("译文") { TextEditor(text: $translation).frame(minHeight: 110).accessibilityLabel("译文") }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            }
            .navigationTitle("编辑字幕").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do { try onSave(source, translation); dismiss() }
                        catch { errorMessage = error.localizedDescription }
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
                Section("整体偏移") {
                    TextField("秒数（可为负数）", text: $secondsText).accessibilityLabel("偏移秒数")
                    Text("正数延后，负数提前。超出媒体范围时不保存。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            }
            .navigationTitle("整体时间偏移").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            guard let seconds = Double(secondsText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                                throw SubtitleTimeOffsetError.invalidOffset
                            }
                            try onSave(SubtitleTimeOffset.milliseconds(from: seconds))
                            dismiss()
                        }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
            }
        }
    }
}


#endif
