#if os(iOS)
import AVKit
import SwiftUI
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

    // 多选重译
    @State private var isSelecting = false
    @State private var selectedCueIDs = Set<UUID>()
    @State private var retranslatingCues: [SubtitleCue]?

    // 导出与烧录
    @State private var sharingURL: URL?
    @State private var showingEmbedding = false
    @State private var showingBurnIn = false
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
                    // 播放器区域
                    VStack(spacing: 0) {
                        playerSection(item, activeCue: activeCue, height: landscape
                            ? max(120, geometry.size.height - 100)
                            : min(260, geometry.size.height * 0.42))

                        // 预览选择栏与倍速
                        previewControlBar
                    }
                    .frame(width: landscape ? geometry.size.width * 0.48 : nil)

                    // 字幕列表与多选区域
                    ZStack(alignment: .bottom) {
                        subtitlesList(item, activeCue: activeCue)

                        if isSelecting {
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
                    let pendingReviewCount = item.cues.filter { $0.requiresTimingReview == true }.count
                    if pendingReviewCount > 0 {
                        Button {
                            do {
                                var updated = item
                                try updated.confirmAllTimingReviews()
                                try library.storage.updateItem(updated, taskID: taskID, comparedTo: item)
                            } catch { errorMessage = error.localizedDescription }
                        } label: {
                            Label("一键校对 (\(pendingReviewCount))", systemImage: "checkmark.seal.fill")
                        }
                    }

                    if !item.cues.isEmpty {
                        Button(isSelecting ? "完成" : "选择") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isSelecting.toggle()
                                if !isSelecting { selectedCueIDs.removeAll() }
                            }
                        }
                    }

                    mediaActionMenu(item)
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
            .sheet(isPresented: $showingEmbedding) {
                IOSSubtitleEmbeddingSheet(item: item, task: task)
            }
            .sheet(isPresented: $showingBurnIn) {
                IOSSubtitleBurnInSheet(item: item)
            }
            .sheet(item: Binding(get: { sharingURL.map { SharePayload(url: $0) } }, set: { sharingURL = $0?.url })) { payload in
                ShareActivitySheet(activityItems: [payload.url])
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
                            isSelecting = false
                            selectedCueIDs.removeAll()
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
            .alert("操作异常", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .task(id: mediaID) { await playback.loadMedia(for: item) }
            .onDisappear { playback.releaseMedia() }
        } else {
            ContentUnavailableView("媒体不存在", systemImage: "film")
        }
    }

    // MARK: - 播放器区域
    @ViewBuilder
    private func playerSection(_ item: TaskMediaItem, activeCue: SubtitleCue?, height: CGFloat) -> some View {
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
                                Text("音轨 \(media.audioTrackID) · \(formatDuration(media.durationMilliseconds))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                    }
                    .frame(height: min(150, height))
                }

                // 悬浮字幕预览
                if let cue = activeCue {
                    VStack(spacing: 3) {
                        if previewKind != .translation {
                            Text(cue.sourceText)
                                .font(.subheadline.weight(.medium))
                        }
                        if previewKind != .source {
                            if case .succeeded(let text, _) = cue.translation, cue.hasCurrentTranslation {
                                Text(text)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("待更新")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
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
            VStack(spacing: 6) {
                HStack(spacing: 10) {
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
                    .tint(Color.voxlineAccent)
                    .disabled(!playback.isReady)

                    Text(playback.formattedDuration)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)

                HStack(spacing: 30) {
                    Button {
                        playback.seekRelative(by: -5)
                    } label: {
                        Image(systemName: "gobackward.5")
                            .font(.title3)
                    }

                    Button {
                        playback.togglePlayPause()
                    } label: {
                        Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 38))
                            .foregroundStyle(Color.voxlineAccent)
                    }

                    Button {
                        playback.seekRelative(by: 5)
                    } label: {
                        Image(systemName: "goforward.5")
                            .font(.title3)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.05))
        } else if playback.isLoading {
            ProgressView("读取本地媒体…")
                .frame(maxWidth: .infinity, minHeight: 140)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "film.stack")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(playback.errorMessage ?? "媒体尚未关联")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("关联本地媒体") {
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
            Picker("字幕预览", selection: $previewKind) {
                Text("原文").tag(SRTOutputKind.source)
                Text("译文").tag(SRTOutputKind.translation)
                Text("双语").tag(SRTOutputKind.bilingual)
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - 字幕列表区域
    @ViewBuilder
    private func subtitlesList(_ item: TaskMediaItem, activeCue: SubtitleCue?) -> some View {
        ScrollViewReader { proxy in
            List {
                // 处理状态栏
                if library.queue.taskID == taskID && library.queue.mediaID == mediaID {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(library.queue.progressText ?? "正在处理…")
                            .font(.caption)
                        Spacer()
                        Button(library.queue.isCancelling ? "取消中" : "取消") {
                            do { try library.queue.cancel(mediaID: mediaID) }
                            catch { errorMessage = error.localizedDescription }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(library.queue.isCancelling)
                    }
                    .padding(.vertical, 2)
                    .listRowBackground(Color.blue.opacity(0.08))
                }

                if item.cues.isEmpty {
                    ContentUnavailableView("暂无字幕内容", systemImage: "character.bubble")
                        .padding(.vertical, 30)
                }

                ForEach(item.cues) { cue in
                    cueRow(cue: cue, item: item, isActive: activeCue?.id == cue.id)
                        .id(cue.id)
                }
            }
            .listStyle(.plain)
            .onChange(of: activeCue?.id) { _, newID in
                if let newID, playback.isPlaying {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - 单行字幕卡片
    @ViewBuilder
    private func cueRow(cue: SubtitleCue, item: TaskMediaItem, isActive: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if isSelecting {
                Button {
                    if selectedCueIDs.contains(cue.id) {
                        selectedCueIDs.remove(cue.id)
                    } else {
                        selectedCueIDs.insert(cue.id)
                    }
                } label: {
                    Image(systemName: selectedCueIDs.contains(cue.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selectedCueIDs.contains(cue.id) ? Color.voxlineAccent : .secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }

            VStack(alignment: .leading, spacing: 6) {
                // 时间轴与操作按钮
                HStack(spacing: 6) {
                    Button {
                        playback.seek(toMilliseconds: cue.startMilliseconds)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 8))
                            Text(formatTime(cue.startMilliseconds))
                            Text("→")
                            Text(formatTime(cue.endMilliseconds))
                        }
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(isActive ? Color.voxlineAccent : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!playback.isReady)

                    Spacer()

                    if task?.parameters.translation != nil && !isSelecting {
                        Button {
                            retranslatingCues = [cue]
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .disabled(library.queue.taskID != nil)
                    }

                    if !isSelecting {
                        Button {
                            editingCue = cue
                        } label: {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }

                // 原文
                Text(cue.sourceText)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)

                // 译文状态
                switch cue.translation {
                case .succeeded(let text, _):
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    if !cue.hasCurrentTranslation {
                        HStack(spacing: 4) {
                            Circle().fill(Color.orange).frame(width: 5, height: 5)
                            Text("原文已修改，译文待更新")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }

                case .failed(let reason):
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.red)

                case .pending:
                    Text("待翻译")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if cue.requiresTimingReview == true {
                    Button {
                        do {
                            var updated = item
                            try updated.confirmTimingReview(cueID: cue.id)
                            try library.storage.updateItem(updated, taskID: taskID, comparedTo: item)
                        } catch { errorMessage = error.localizedDescription }
                    } label: {
                        Label("确认校对", systemImage: "checkmark.circle")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(isActive ? Color.voxlineAccent.opacity(0.08) : nil)
    }

    // MARK: - 多选悬浮操作栏
    @ViewBuilder
    private func selectionActionBar(_ item: TaskMediaItem) -> some View {
        HStack(spacing: 16) {
            Button("全选") {
                selectedCueIDs = Set(item.cues.map(\.id))
            }
            .font(.subheadline)

            Button("取消全选") {
                selectedCueIDs.removeAll()
            }
            .font(.subheadline)

            Spacer()

            Text("已选 \(selectedCueIDs.count) 句")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Button {
                let targets = item.cues.filter { selectedCueIDs.contains($0.id) }
                retranslatingCues = targets
            } label: {
                Label("重译所选", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.bold())
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(selectedCueIDs.isEmpty || library.queue.taskID != nil)
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
            // 导出与分享子菜单
            Menu {
                Button {
                    shareSRT(kind: .source, item: item)
                } label: {
                    Label("导出原文字幕 (.srt)", systemImage: "doc.text")
                }
                .disabled(item.cues.isEmpty)

                Button {
                    shareSRT(kind: .translation, item: item)
                } label: {
                    Label("导出译文字幕 (.srt)", systemImage: "doc.text.fill")
                }
                .disabled(item.cues.isEmpty)

                Button {
                    shareSRT(kind: .bilingual, item: item)
                } label: {
                    Label("导出双语字幕 (.srt)", systemImage: "doc.on.doc")
                }
                .disabled(item.cues.isEmpty)

                if item.kind == .video {
                    Divider()
                    Button {
                        showingEmbedding = true
                    } label: {
                        Label("内封软字幕视频 (.mp4)…", systemImage: "captions.bubble")
                    }
                    .disabled(item.cues.isEmpty)

                    Button {
                        showingBurnIn = true
                    } label: {
                        Label("烧录字幕视频 (.mp4)…", systemImage: "film")
                    }
                    .disabled(item.cues.isEmpty)
                }

                if let currentTask = task {
                    Divider()
                    Button {
                        shareTask(currentTask)
                    } label: {
                        Label("分享任务文件 (.voxline)", systemImage: "square.and.arrow.up")
                    }
                }
            } label: {
                Label("导出与分享", systemImage: "square.and.arrow.up")
            }

            Divider()

            let hasTranslation = task?.parameters.translation != nil
            if hasTranslation {
                if !item.cues.isEmpty && !item.cues.allSatisfy(\.hasCurrentTranslation) {
                    Button("继续翻译未完成", systemImage: "character.bubble") {
                        do { try library.startTranslation(taskID: taskID, mediaID: mediaID) }
                        catch { errorMessage = error.localizedDescription }
                    }
                    .disabled(library.queue.taskID != nil || !item.hasCompletedTranscription)
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

            Divider()

            Button("重新关联媒体…", systemImage: "paperclip") {
                importingMedia = true
            }

            Button("整体时间偏移…", systemImage: "clock") {
                showingOffset = true
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
        }
    }

    private func shareSRT(kind: SRTOutputKind, item: TaskMediaItem) {
        do {
            let url = try IOSExportHelper.prepareSRT(for: item, kind: kind)
            sharingURL = url
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func shareTask(_ task: ProcessingTask) {
        do {
            let url = try IOSExportHelper.prepareTaskArchive(for: task)
            sharingURL = url
        } catch {
            errorMessage = error.localizedDescription
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
                Section("原文") {
                    TextEditor(text: $source)
                        .frame(minHeight: 100)
                }
                Section("译文") {
                    TextEditor(text: $translation)
                        .frame(minHeight: 100)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("编辑字幕")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            try onSave(source, translation)
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
                    TextField("偏移秒数（支持小数或负数）", text: $secondsText)
                        .keyboardType(.numbersAndPunctuation)
                } footer: {
                    Text("正数延后，负数提前。")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("整体时间偏移")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
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
