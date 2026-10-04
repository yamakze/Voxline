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

    private var item: TaskMediaItem? { library.task(taskID)?.items.first { $0.id == mediaID } }

    var body: some View {
        if let item {
            GeometryReader { geometry in
                let landscape = geometry.size.width > geometry.size.height
                let layout = landscape ? AnyLayout(HStackLayout(alignment: .top, spacing: 0))
                    : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    VStack(spacing: 0) {
                        player(item, height: landscape ? max(80, geometry.size.height - 96)
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
                        if item.cues.isEmpty { Text("还没有字幕成果").foregroundStyle(.secondary) }
                        ForEach(item.cues) { cue in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Button(time(cue.startMilliseconds)) { playback.seek(toMilliseconds: cue.startMilliseconds) }
                                        .font(.caption.monospacedDigit()).disabled(!playback.isReady)
                                    Text("→ \(time(cue.endMilliseconds))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("编辑字幕", systemImage: "pencil") { editingCue = cue }
                                        .labelStyle(.iconOnly)
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
                                            try library.updateItem(updated, taskID: taskID, comparedTo: item)
                                        } catch { errorMessage = error.localizedDescription }
                                    }
                                }
                            }
                            .padding(.vertical, 6)
                            .listRowBackground(playback.activeCue(in: item.cues)?.id == cue.id ? Color.primary.opacity(0.08) : nil)
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu("媒体操作", systemImage: "ellipsis") {
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
                    try library.updateItem(updated, taskID: taskID, comparedTo: candidate.item)
                }
            }
            .sheet(item: $editingCue) { cue in
                IOSSubtitleEditor(cue: cue) { source, translation in
                    guard var updated = self.item, let index = updated.cues.firstIndex(where: { $0.id == cue.id }),
                          updated.cues[index].sourceText == cue.sourceText,
                          updated.cues[index].sourceRevision == cue.sourceRevision,
                          updated.cues[index].translation == cue.translation else { throw CheckpointError.editedCue }
                    let original = updated
                    try updated.cues[index].replaceSourceText(with: source)
                    let previous: String
                    if case .succeeded(let text, _) = cue.translation { previous = text } else { previous = "" }
                    if translation != previous {
                        updated.cues[index].translation = translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? .pending : .succeeded(text: translation, sourceRevision: updated.cues[index].sourceRevision)
                    }
                    if updated.status == .completed || updated.status == .needsReview,
                       let checkpoint = updated.checkpoint, checkpoint.chunks.allSatisfy(\.isCompleted) {
                        updated.status = checkpoint.parameters.translation == nil || updated.cues.allSatisfy(\.hasCurrentTranslation)
                            ? updated.completedProcessingStatus : .needsReview
                    }
                    try library.updateItem(updated, taskID: taskID, comparedTo: original)
                }
            }
            .sheet(isPresented: $showingOffset) {
                IOSSubtitleOffsetEditor { milliseconds in
                    guard var updated = self.item else { throw TaskValidationError.taskChanged }
                    let original = updated
                    updated.cues = try SubtitleTimeOffset.shifted(updated.cues, by: milliseconds,
                                                                 withinDuration: updated.media?.durationMilliseconds)
                    try library.updateItem(updated, taskID: taskID, comparedTo: original)
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

    @ViewBuilder private func player(_ item: TaskMediaItem, height: CGFloat) -> some View {
        if let player = playback.player {
            ZStack(alignment: .bottom) {
                VideoPlayer(player: player).frame(height: item.kind == .video ? height : min(130, height))
                if let cue = playback.activeCue(in: item.cues) {
                    VStack(spacing: 4) {
                        if previewKind != .translation { Text(cue.sourceText) }
                        if previewKind != .source {
                            if case .succeeded(let text, _) = cue.translation, cue.hasCurrentTranslation { Text(text) }
                            else { Text("译文待更新") }
                        }
                    }
                    .font(.callout).multilineTextAlignment(.center)
                    .padding(8).modifier(IOSSubtitleSurface())
                    .padding(.horizontal, 12).padding(.bottom, 48).allowsHitTesting(false)
                }
            }
            HStack(spacing: 18) {
                Button("后退 5 秒", systemImage: "gobackward.5") { playback.seekRelative(by: -5) }
                Button(playback.isPlaying ? "暂停" : "播放", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
                    playback.togglePlayPause()
                }
                Button("前进 5 秒", systemImage: "goforward.5") { playback.seekRelative(by: 5) }
                Text(playback.formattedCurrentTime).font(.caption.monospacedDigit())
                Spacer()
            }
            .labelStyle(.iconOnly).padding(.horizontal).padding(.vertical, 8).disabled(!playback.isReady)
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


private struct IOSSubtitleSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 10))
        } else if #available(iOS 26, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

#endif
