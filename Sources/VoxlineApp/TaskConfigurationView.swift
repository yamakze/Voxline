import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VoxlineCore
import VoxlineMedia

public struct TaskConfigurationView: View {
    @Binding var task: ProcessingTask
    var onCommit: ((ProcessingTask) throws -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var draftTitle: String
    @State private var modelID: String
    @State private var languageMode: TranscriptionSettings.LanguageMode
    @State private var languageCode: String
    @State private var translates: Bool
    @State private var selectedServiceID: UUID?
    @State private var translationModel: String
    @State private var targetLanguage: String
    @State private var outputs: Set<SRTOutputKind>

    @State private var existingItems: [TaskMediaItem]
    @State private var candidates: [ImportCandidate] = []
    @State private var isInspecting = false
    @State private var importTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showModelManager = false
    @State private var showTranslationSettings = false

    private let inspector = MediaInspector.shared
    private let modelManager = ModelManager.shared
    private let serviceStore = TranslationServiceStore.shared
    @State private var originalTask: ProcessingTask

    public init(task: Binding<ProcessingTask>, onCommit: ((ProcessingTask) throws -> Void)? = nil) {
        _task = task
        self.onCommit = onCommit
        let value = task.wrappedValue
        _originalTask = State(initialValue: value)
        _draftTitle = State(initialValue: value.title)
        _modelID = State(initialValue: value.parameters.transcription.modelID)
        _languageMode = State(initialValue: value.parameters.transcription.languageMode)
        _languageCode = State(initialValue: value.parameters.transcription.languageCode ?? "en")
        _translates = State(initialValue: value.parameters.translation != nil)
        _selectedServiceID = State(initialValue: value.parameters.translation?.serviceID)
        _translationModel = State(initialValue: value.parameters.translation?.modelID ?? "gpt-4o-mini")
        _targetLanguage = State(initialValue: value.parameters.translation?.targetLanguage ?? "zh-Hans")
        _outputs = State(initialValue: Set(value.parameters.srtOutputs))
        _existingItems = State(initialValue: value.items)
    }

    private struct ImportCandidate: Identifiable {
        let id = UUID()
        let url: URL
        let kind: TaskMediaKind
        var inspection: MediaInspection?
        var trackID: Int32?
        var error: String?
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Sheet Header Bar (Pages / FCP style)
            sheetHeaderBar
            Divider()

            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
                    .textSelection(.enabled).padding(.horizontal, 20).padding(.vertical, 8)
            }

            // Main Dual-Pane: Left (FCP Media Import & Audio Track Inspector) + Right (Pages Parameters Form)
            HSplitView {
                // Left Column: Final Cut Pro Media Import & Tracks Panel
                fcpMediaImportPane
                    .frame(minWidth: 420, idealWidth: 460)

                // Right Column: Pages/Keynote Parameters Form with DisclosureGroups
                pagesParametersPane
                    .frame(minWidth: 380, idealWidth: 420)
            }

            Divider()

            // Bottom Action Bar
            bottomActionBar
        }
        .frame(minWidth: 840, idealWidth: 900, minHeight: 600, idealHeight: 650)
        .sheet(isPresented: $showModelManager) {
            NavigationStack {
                ModelManagementView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("完成") { showModelManager = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showTranslationSettings) {
            NavigationStack {
                TranslationServicesSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("完成") {
                                showTranslationSettings = false
                                if selectedServiceID == nil, let first = serviceStore.services.first {
                                    selectedServiceID = first.id
                                }
                            }
                        }
                    }
            }
        }
        .onChange(of: translates) { _, enabled in
            if !enabled {
                outputs = [.source]
            } else if selectedServiceID == nil, let first = serviceStore.services.first {
                selectedServiceID = first.id
                translationModel = first.modelID
            }
        }
        .onDisappear {
            importTask?.cancel()
            saveTask?.cancel()
        }
        .onAppear {
            if translates && selectedServiceID == nil {
                selectedServiceID = serviceStore.services.first?.id
            }
        }
    }

    // MARK: - Sheet Header Bar
    private var sheetHeaderBar: some View {
        HStack(alignment: .center) {
            Image(systemName: "film.stack")
                .font(.title2)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(originalTask.items.isEmpty ? "新建任务" : "任务准备")
                    .font(.headline)
            }

            Spacer()

            Button("取消") {
                importTask?.cancel()
                saveTask?.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    // MARK: - Left: Final Cut Pro Media Import & Tracks Panel
    private var fcpMediaImportPane: some View {
        VStack(spacing: 0) {
            // Pane Sub-header
            HStack {
                Label("导入媒体队列", systemImage: "arrow.down.doc.fill")
                    .font(.subheadline.bold())
                Spacer()
                Button("添加音视频…", systemImage: "plus") {
                    chooseMedia()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isInspecting)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Media list
            ScrollView {
                VStack(spacing: 12) {
                    if existingItems.isEmpty && candidates.isEmpty {
                        // FCP-style Drag & Drop target area
                        VStack(spacing: 12) {
                            Text("添加本地媒体")
                                .font(.callout.bold())
                            Text("MP4, MOV, M4V, M4A, MP3, WAV")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(32)
                        .frame(maxWidth: .infinity)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                                .foregroundStyle(Color.secondary.opacity(0.3))
                        )
                        .padding(16)
                    }

                    // Existing Items List
                    ForEach(Array(existingItems.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 10) {
                            Image(systemName: item.kind == .video ? "film" : "waveform")
                                .font(.title3)
                                .foregroundStyle(item.kind == .video ? .blue : .purple)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.system(size: 13, weight: .semibold))
                                Text(item.media == nil ? "未关联" : item.status.label)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()

                            Button { existingItems.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }
                                .buttonStyle(.plain).disabled(index == 0)
                            Button { existingItems.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }
                                .buttonStyle(.plain).disabled(index == existingItems.count - 1)
                            Button { existingItems.remove(at: index) } label: { Image(systemName: "trash").foregroundStyle(.red) }
                                .buttonStyle(.plain)
                        }
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
                    }

                    // Newly selected candidates
                    ForEach($candidates) { $candidate in
                        fcpCandidateCard(candidate: $candidate)
                    }

                    if isInspecting {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在读取轨道信息与内容哈希…").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding(14)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func fcpCandidateCard(candidate: Binding<ImportCandidate>) -> some View {
        let cand = candidate.wrappedValue
        VStack(alignment: .leading, spacing: 8) {
            candidateHeader(cand: cand)
            if let inspection = cand.inspection {
                candidateTracksView(candidate: candidate, inspection: inspection)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
    }

    @ViewBuilder
    private func candidateHeader(cand: ImportCandidate) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(cand.kind == .video ? Color.blue.opacity(0.15) : Color.purple.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: cand.kind == .video ? "film" : "waveform")
                    .font(.title3)
                    .foregroundStyle(cand.kind == .video ? .blue : .purple)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(cand.url.lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                if let inspection = cand.inspection {
                    HStack(spacing: 8) {
                        Text(cand.kind == .video ? "视频" : "音频")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: .capsule)
                        let sec = Double(inspection.durationMilliseconds) / 1000.0
                        Text(String(format: "%.1fs", sec))
                        let mb = Double(inspection.byteCount) / 1_048_576.0
                        Text(String(format: "%.1fMB", mb))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    ForEach(inspection.videoTracks) { track in
                        Text("视频轨 \(track.id) · \(track.codecs.joined(separator: ", ")) · \(track.isDecodable ? "可解码" : "无法解码")")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else if let error = cand.error {
                    Text(error).font(.caption2).foregroundStyle(.red)
                } else {
                    Text("解析中…").font(.caption2).foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                candidates.removeAll { $0.id == cand.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func candidateTracksView(candidate: Binding<ImportCandidate>, inspection: MediaInspection) -> some View {
        let cand = candidate.wrappedValue
        VStack(alignment: .leading, spacing: 4) {
            Text("选择处理音轨：")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)

            ForEach(inspection.audioTracks) { track in
                let isSelected = (cand.trackID == track.id)
                Button {
                    if track.isDecodable {
                        candidate.trackID.wrappedValue = track.id
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                            .font(.caption)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                        Text("音轨 \(track.id)")
                            .font(.caption.monospacedDigit().bold())

                        Text(track.language ?? "未知语言")
                            .font(.caption)

                        Text(track.codecs.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Text(track.isDecodable ? "可解码" : "无法解码")
                            .font(.caption2)
                            .foregroundStyle(track.isDecodable ? Color.secondary : .red)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear, in: .rect(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(!track.isDecodable)
            }

            if cand.trackID == nil {
                Text("⚠️ 请明确选择一个转写音轨")
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 6))
    }

    // MARK: - Right: Pages/Keynote Parameters Form
    private var pagesParametersPane: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Group 1: Task Title
                DisclosureGroup(isExpanded: .constant(true)) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("任务名称", text: $draftTitle)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(.top, 6)
                } label: {
                    Label("任务信息", systemImage: "doc.text")
                        .font(.subheadline.bold())
                }
                .padding(12)
                .liquidGlassSurface()

                // Group 2: Transcription Engine
                DisclosureGroup(isExpanded: .constant(true)) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("模型", selection: $modelID) {
                            if !ModelManager.availableModels.contains(where: { $0.id == modelID }) {
                                Text("尚未支持：\(modelID)").tag(modelID)
                            }
                            ForEach(ModelManager.availableModels) { model in
                                Text(model.name).tag(model.id)
                            }
                        }

                        let status = modelManager.status(for: modelID)
                        HStack(spacing: 6) {
                            Text("状态：")
                            switch status {
                            case .ready:
                                Text(status.label).foregroundStyle(.green)
                            case .downloaded:
                                Text(status.label).foregroundStyle(.secondary)
                                Button("加载") { modelManager.load(modelID: modelID) }
                                    .buttonStyle(.borderless)
                            case .downloading, .checking, .cancelling:
                                Text(status.label).foregroundStyle(.blue)
                            case .notDownloaded, .cancelled:
                                Text("未下载（建议提前就绪）").foregroundStyle(.orange)
                                Button("下载") { modelManager.download(modelID: modelID) }
                                    .buttonStyle(.borderless)
                            case .failed, .corrupted:
                                Text(status.label).foregroundStyle(.red)
                            case .loading:
                                Text("加载中…").foregroundStyle(.blue)
                            }
                            Spacer()
                            Button("模型管理…", systemImage: "square.grid.2x2") {
                                showModelManager = true
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                        .font(.caption2)

                        Divider()

                        Picker("原文语言", selection: $languageMode) {
                            Text("自动识别语言").tag(TranscriptionSettings.LanguageMode.automatic)
                            Text("指定语言代码").tag(TranscriptionSettings.LanguageMode.specified)
                        }

                        if languageMode == .specified {
                            TextField("语言代码（如 en / ja）", text: $languageCode)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Label("转写引擎 (WhisperKit)", systemImage: "cpu")
                        .font(.subheadline.bold())
                }
                .padding(12)
                .liquidGlassSurface()

                // Group 3: Subtitle Translation
                DisclosureGroup(isExpanded: .constant(true)) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("启用字幕翻译", isOn: $translates)

                        if translates {
                            if serviceStore.services.isEmpty {
                                HStack {
                                    Text("尚未配置翻译服务")
                                        .font(.caption).foregroundStyle(.orange)
                                    Spacer()
                                    Button("去配置", systemImage: "gear") {
                                        showTranslationSettings = true
                                    }
                                }
                            } else {
                                Picker("服务提供商", selection: $selectedServiceID) {
                                    Text("请选择服务").tag(nil as UUID?)
                                    ForEach(serviceStore.services) { service in
                                        Text(service.name).tag(Optional(service.id))
                                    }
                                }
                            }

                            TextField("翻译模型（如 gpt-4o-mini）", text: $translationModel)
                                .textFieldStyle(.roundedBorder)

                            TextField("目标语言（默认 zh-Hans）", text: $targetLanguage)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Label("字幕翻译 (OpenAI 兼容)", systemImage: "character.bubble")
                        .font(.subheadline.bold())
                }
                .padding(12)
                .liquidGlassSurface()

                // Group 4: Output SRT Options
                DisclosureGroup(isExpanded: .constant(true)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("原文 SRT (.en.srt)", isOn: Binding(
                            get: { outputs.contains(.source) },
                            set: { if $0 { outputs.insert(.source) } else { outputs.remove(.source) } }
                        ))

                        Toggle("译文 SRT (.zh.srt)", isOn: Binding(
                            get: { outputs.contains(.translation) },
                            set: { if $0 { outputs.insert(.translation) } else { outputs.remove(.translation) } }
                        ))
                        .disabled(!translates)

                        Toggle("双语 SRT (.bilingual.srt)", isOn: Binding(
                            get: { outputs.contains(.bilingual) },
                            set: { if $0 { outputs.insert(.bilingual) } else { outputs.remove(.bilingual) } }
                        ))
                        .disabled(!translates)
                    }
                    .padding(.top, 6)
                } label: {
                    Label("字幕导出选项", systemImage: "doc.badge.arrow.up")
                        .font(.subheadline.bold())
                }
                .padding(12)
                .liquidGlassSurface()
            }
            .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Bottom Action Bar
    private var bottomActionBar: some View {
        HStack(spacing: 12) {
            // Left: Preflight check status chip
            if let blockReason = preflightBlockReason {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(blockReason).font(.caption).foregroundStyle(.orange)
                }
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    let totalCount = existingItems.count + candidates.filter({ $0.error == nil }).count
                    Text("可准备 \(totalCount) 个媒体，保存时校验参数").font(.caption).foregroundStyle(.green)
                }
            }

            Spacer()

            Button("保存草稿") {
                saveTask = Task { await commitTask() }
            }
            .disabled(isInspecting || isSaving)

            Text(ProcessingAvailability.reason)
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    private var preflightBlockReason: String? {
        let totalCount = existingItems.count + candidates.filter({ $0.error == nil }).count
        if totalCount == 0 {
            return "请先在左侧添加音视频。"
        }
        for candidate in candidates where candidate.error == nil {
            if candidate.inspection != nil && candidate.trackID == nil {
                return "媒体“\(candidate.url.lastPathComponent)”尚未选择音轨。"
            }
        }
        if translates {
            if selectedServiceID == nil || serviceStore.services.isEmpty {
                return "开启翻译时需选择已配置的翻译服务。"
            }
            if translationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "翻译模型名称不能为空。"
            }
        }
        return nil
    }

    private func chooseMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .mpeg4Movie, .quickTimeMovie, UTType(importedAs: "com.apple.m4v-video"),
            .mpeg4Audio, .mp3, .wav
        ]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "导入媒体"

        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            panel.orderOut(nil)
            if response == .OK {
                let urls = panel.urls
                importTask = Task {
                    isInspecting = true
                    defer { isInspecting = false }

                    let additions = urls.filter { url in
                        !candidates.contains { $0.url == url }
                    }

                    for url in additions {
                        if Task.isCancelled { return }
                        let kind: TaskMediaKind
                        do { kind = try MediaInspector.kind(of: url) }
                        catch {
                            errorMessage = "\(url.lastPathComponent)：\(error.localizedDescription)"
                            continue
                        }
                        let candidate = ImportCandidate(url: url, kind: kind)
                        candidates.append(candidate)
                        do {
                            let inspection = try await inspector.inspect(url)
                            try Task.checkCancellation()
                            if let idx = candidates.firstIndex(where: { $0.id == candidate.id }) {
                                candidates[idx].inspection = inspection
                                if inspection.audioTracks.count == 1 {
                                    candidates[idx].trackID = inspection.audioTracks[0].id
                                }
                            }
                        } catch is CancellationError {
                            return
                        } catch {
                            if let idx = candidates.firstIndex(where: { $0.id == candidate.id }) {
                                candidates[idx].error = error.localizedDescription
                            }
                        }
                    }
                }
            }
        }
    }

    private func commitTask() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let transcription = TranscriptionSettings(
                modelID: modelID,
                languageMode: languageMode,
                languageCode: languageMode == .specified ? languageCode : nil
            )

            var translation: TranslationSettings?
            if translates {
                guard let serviceID = selectedServiceID,
                      let service = serviceStore.services.first(where: { $0.id == serviceID }) else {
                    throw TaskValidationError.unconfiguredTranslationService
                }
                translation = try TranslationSettings(
                    baseURL: service.baseURL,
                    modelID: translationModel,
                    targetLanguage: targetLanguage,
                    serviceID: serviceID
                )
            }

            var updated = originalTask
            updated.title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if updated.title.isEmpty { updated.title = "未命名任务" }

            try updated.updateParameters(TaskParameters(
                transcription: transcription,
                translation: translation,
                srtOutputs: [.source, .translation, .bilingual].filter { outputs.contains($0) }
            ))

            var newItems: [TaskMediaItem] = existingItems
            var addedBookmarkPairs: [(TaskMediaItem, MediaInspection, Int32)] = []

            for candidate in candidates {
                if let failure = candidate.error {
                    let failedItem = TaskMediaItem(
                        id: candidate.id,
                        title: candidate.url.deletingPathExtension().lastPathComponent,
                        kind: candidate.kind,
                        source: .localFile(fileName: candidate.url.lastPathComponent),
                        status: .failed(reason: failure)
                    )
                    newItems.append(failedItem)
                    continue
                }

                guard let inspection = candidate.inspection, let trackID = candidate.trackID else {
                    errorMessage = "\(candidate.url.lastPathComponent)：请先选择转写音轨。"
                    return
                }

                var item = TaskMediaItem(
                    id: candidate.id,
                    title: candidate.url.deletingPathExtension().lastPathComponent,
                    kind: candidate.kind,
                    source: .unassociated
                )
                try item.associateMedia(inspection.identity(audioTrackID: trackID))
                newItems.append(item)
                addedBookmarkPairs.append((item, inspection, trackID))
            }

            updated.items = newItems
            try updated.validate()

            for (item, inspection, trackID) in addedBookmarkPairs {
                do {
                    let identity = try await inspector.confirm(inspection, audioTrackID: trackID)
                    try await LocalMediaStore.shared.save(projectID: item.id, identity: identity, url: inspection.url)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if let index = updated.items.firstIndex(where: { $0.id == item.id }) {
                        updated.items[index] = TaskMediaItem(id: item.id, title: item.title, kind: item.kind,
                            source: .localFile(fileName: inspection.url.lastPathComponent),
                            status: .failed(reason: error.localizedDescription))
                    }
                }
            }
            try Task.checkCancellation()
            guard task == originalTask else { throw TaskValidationError.taskChanged }
            try updated.validate()
            try onCommit?(updated)
            task = updated
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
