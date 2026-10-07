import VoxlineTranslation
import VoxlineWhisperKit
import SwiftUI
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
    private enum TranslationEngineChoice { case api, apple }
    @State private var translationEngine: TranslationEngineChoice
    @State private var appleSourceLanguage: String
    @State private var appleBatchSize: Int
    @State private var translates: Bool
    @State private var selectedServiceID: UUID?
    @State private var translationModel: String
    @State private var targetLanguage: String
    @State private var translationBatchSize: Int
    @State private var translationSystemPrompt: String
    @State private var showAdvancedTranslationOptions = false
    @State private var outputs: Set<SRTOutputKind>

    @State private var existingItems: [TaskMediaItem]
    @State private var candidates: [ImportCandidate] = []
    @State private var isInspecting = false
    @State private var importTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showMediaImporter = false
    @State private var confirmTranslationReplacement = false
    @State private var showModelManager = false
    @State private var showTranslationSettings = false

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var iosActiveTab = 0
    #endif

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
        if case .appleTranslation(let source) = value.parameters.translation?.engine {
            _translationEngine = State(initialValue: .apple)
            _appleSourceLanguage = State(initialValue: source)
            _appleBatchSize = State(initialValue: value.parameters.translation?.batchSize ?? TranslationSettings.defaultBatchSize)
        } else {
            _translationEngine = State(initialValue: .api)
            _appleSourceLanguage = State(initialValue: "en")
            _appleBatchSize = State(initialValue: TranslationSettings.defaultBatchSize)
        }
        _translates = State(initialValue: value.parameters.translation != nil)
        _selectedServiceID = State(initialValue: value.parameters.translation?.api?.serviceID)
        _translationModel = State(initialValue: value.parameters.translation?.api?.modelID ?? "gpt-4o-mini")
        _targetLanguage = State(initialValue: value.parameters.translation?.targetLanguage ?? "zh-Hans")
        _translationBatchSize = State(initialValue: value.parameters.translation?.batchSize ?? TranslationSettings.defaultBatchSize)
        _translationSystemPrompt = State(initialValue: value.parameters.translation?.api?.systemPrompt ?? TranslationSettings.defaultSystemPrompt)
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
        Group {
            #if os(macOS)
            macosBody
            #else
            iosBody
            #endif
        }
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
        .fileImporter(isPresented: $showMediaImporter, allowedContentTypes: [
            .mpeg4Movie, .quickTimeMovie, UTType(importedAs: "com.apple.m4v-video"),
            .mpeg4Audio, .mp3, .wav
        ], allowsMultipleSelection: true) { result in
            switch result {
            case .failure(let error): errorMessage = error.localizedDescription
            case .success(let urls):
                importTask = Task {
                    isInspecting = true
                    defer { isInspecting = false }

                    let additions = urls.filter { url in
                        !candidates.contains { $0.url == url }
                    }

                    for url in additions {
                        if Task.isCancelled { return }
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }

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
        .onChange(of: translates) { _, enabled in
            if !enabled {
                outputs = [.source]
            } else if selectedServiceID == nil, let first = serviceStore.services.first {
                selectedServiceID = first.id
                translationModel = first.modelID
            }
        }
        .onChange(of: selectedServiceID) { _, id in
            if let service = serviceStore.services.first(where: { $0.id == id }) {
                translationModel = service.modelID
                translationBatchSize = service.batchSize
                translationSystemPrompt = service.systemPrompt
            }
        }
        .onChange(of: serviceStore.services) { _, services in
            if let service = services.first(where: { $0.id == selectedServiceID }) {
                translationBatchSize = service.batchSize
                translationSystemPrompt = service.systemPrompt
            }
        }
        .confirmationDialog("更换目标语言？", isPresented: $confirmTranslationReplacement, titleVisibility: .visible) {
            Button("清除现有译文并保存", role: .destructive) {
                saveTask = Task { await commitTask(discardingTranslations: true) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("现有译文将清除，原文、时间、转写成果和待校对标记保持。保存后可继续翻译。")
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

    #if os(macOS)
    private var macosBody: some View {
        VStack(spacing: 0) {
            sheetHeaderBar
            Divider()

            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
                    .textSelection(.enabled).padding(.horizontal, 20).padding(.vertical, 8)
            }

            HSplitView {
                fcpMediaImportPane
                    .frame(minWidth: 420, idealWidth: 460)

                pagesParametersPane
                    .frame(minWidth: 380, idealWidth: 420)
            }

            Divider()

            bottomActionBar
        }
        .frame(minWidth: 840, idealWidth: 900, minHeight: 600, idealHeight: 650)
    }
    #endif

    #if os(iOS)
    private var iosBody: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.red)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.08))
                }

                if horizontalSizeClass == .regular {
                    HStack(spacing: 0) {
                        fcpMediaImportPane
                            .frame(minWidth: 320, maxWidth: .infinity)
                        Divider()
                        pagesParametersPane
                            .frame(minWidth: 360, maxWidth: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        let totalCount = existingItems.count + candidates.count
                        Picker("", selection: $iosActiveTab) {
                            Text("媒体 (\(totalCount))").tag(0)
                            Text("参数").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)

                        Divider()

                        if iosActiveTab == 0 {
                            fcpMediaImportPane
                        } else {
                            pagesParametersPane
                        }
                    }
                }
            }
            .navigationTitle(originalTask.items.isEmpty ? "新建任务" : "任务准备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        importTask?.cancel()
                        saveTask?.cancel()
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(originalTask.startedAt == nil ? "保存任务" : "保存参数") {
                        saveTask = Task { await commitTask() }
                    }
                    .bold()
                    .disabled(isInspecting || isSaving || preflightBlockReason != nil)
                }
            }
        }
    }
    #endif

    // MARK: - Sheet Header Bar
    private var sheetHeaderBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "film.stack")
                .font(.title3)
                .foregroundStyle(.tint)

            Text(originalTask.items.isEmpty ? "新建任务" : "任务准备")
                .font(.headline)

            Spacer()

            Button("取消") {
                importTask?.cancel()
                saveTask?.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isSaving)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    // MARK: - Left: Media Import & Tracks Panel
    private var fcpMediaImportPane: some View {
        VStack(spacing: 0) {
            // Pane Sub-header
            HStack {
                let totalCount = existingItems.count + candidates.count
                Text("媒体列表")
                    .font(.subheadline.bold())
                if totalCount > 0 {
                    Text("(\(totalCount))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    showMediaImporter = true
                } label: {
                    Label("添加…", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isInspecting)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.voxlineControlBackground)

            Divider()

            // Media list
            ScrollView {
                VStack(spacing: 10) {
                    if existingItems.isEmpty && candidates.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.down.doc")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                            Text("添加音视频媒体文件")
                                .font(.callout.weight(.medium))
                            Text("支持 MP4, MOV, M4V, M4A, MP3, WAV")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(32)
                        .frame(maxWidth: .infinity)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                                .foregroundStyle(Color.secondary.opacity(0.25))
                        )
                        .padding(14)
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
                        .background(Color.voxlineControlBackground, in: .rect(cornerRadius: 8))
                    }

                    // Newly selected candidates
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, _ in
                        candidateCard(index: index, candidate: $candidates[index])
                    }

                    if isInspecting {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在读取轨道信息…").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding(12)
            }
        }
        .background(Color.voxlineWindowBackground)
    }

    @ViewBuilder
    private func candidateCard(index: Int, candidate: Binding<ImportCandidate>) -> some View {
        let cand = candidate.wrappedValue
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(cand.kind == .video ? Color.blue.opacity(0.12) : Color.purple.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: cand.kind == .video ? "film" : "waveform")
                        .font(.system(size: 18))
                        .foregroundStyle(cand.kind == .video ? .blue : .purple)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(cand.url.lastPathComponent)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    if let inspection = cand.inspection {
                        HStack(spacing: 6) {
                            Text(cand.kind == .video ? "视频" : "音频")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.12), in: .capsule)
                            let sec = Double(inspection.durationMilliseconds) / 1000.0
                            Text(String(format: "%.1fs", sec))
                            Text("•").foregroundStyle(.tertiary)
                            let mb = Double(inspection.byteCount) / 1_048_576.0
                            Text(String(format: "%.1f MB", mb))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    } else if let error = cand.error {
                        Text(error).font(.caption2).foregroundStyle(.red)
                    } else {
                        Text("解析中…").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button {
                    candidates.swapAt(index, index - 1)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.plain)
                .disabled(index == 0)

                Button {
                    candidates.swapAt(index, index + 1)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .buttonStyle(.plain)
                .disabled(index == candidates.count - 1)

                Button {
                    candidates.removeAll { $0.id == cand.id }
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }

            if let inspection = cand.inspection {
                if inspection.audioTracks.count > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("选择转写音轨：")
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
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 6))
                }

                if cand.trackID == nil {
                    Text("请选择转写音轨")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(10)
        .background(Color.voxlineControlBackground, in: .rect(cornerRadius: 8))
    }

    // MARK: - Right: Parameters Form
    private var pagesParametersPane: some View {
        Form {
            Section("基本信息") {
                TextField("任务名称", text: $draftTitle, prompt: Text("输入任务名称"))
            }

            Section("语音转写") {
                Picker("转写模型", selection: $modelID) {
                    if !ModelManager.availableModels.contains(where: { $0.id == modelID }) {
                        Text("未收录：\(modelID)").tag(modelID)
                    }
                    ForEach(ModelManager.availableModels) { model in
                        Text(model.name).tag(model.id)
                    }
                }

                HStack {
                    let status = modelManager.status(for: modelID)
                    HStack(spacing: 5) {
                        switch status {
                        case .ready, .downloaded:
                            Circle().fill(Color.green).frame(width: 7, height: 7)
                            Text("已就绪").foregroundStyle(.green)
                        case .downloading, .checking:
                            ProgressView().controlSize(.mini)
                            Text("下载中…").foregroundStyle(.blue)
                        case .notDownloaded, .cancelled:
                            Text("未下载").foregroundStyle(.secondary)
                            Button("下载") { modelManager.download(modelID: modelID) }
                                .buttonStyle(.borderless)
                        case .failed, .corrupted:
                            Text("异常").foregroundStyle(.red)
                        case .loading, .cancelling:
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .font(.caption)

                    Spacer()

                    Button("管理模型") {
                        showModelManager = true
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }

                Picker("原文语言", selection: $languageMode) {
                    Text("自动识别").tag(TranscriptionSettings.LanguageMode.automatic)
                    Text("指定语言").tag(TranscriptionSettings.LanguageMode.specified)
                }

                if languageMode == .specified {
                    LanguagePicker(title: "语言", selection: $languageCode, identifiers: WhisperKitLanguages.codes)
                }

                if !originalTask.canChangeTranscription {
                    Text("已有转写记录，模型与原文语言已锁定")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!originalTask.canChangeTranscription)

            Section("字幕翻译") {
                Toggle("启用字幕翻译", isOn: $translates)

                if translates {
                    Picker("翻译服务", selection: $translationEngine) {
                        Text("OpenAI 接口").tag(TranslationEngineChoice.api)
                        Text("Apple Translation (本机)").tag(TranslationEngineChoice.apple)
                    }

                    if translationEngine == .apple {
                        AppleTranslationLanguageSettings(
                            source: $appleSourceLanguage,
                            target: $targetLanguage,
                            batchSize: $appleBatchSize
                        )
                    } else {
                        if serviceStore.services.isEmpty {
                            HStack {
                                Text("尚未配置翻译服务")
                                    .font(.caption).foregroundStyle(.orange)
                                Spacer()
                                Button("去配置…") {
                                    showTranslationSettings = true
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        } else {
                            Picker("服务提供商", selection: $selectedServiceID) {
                                Text("请选择服务").tag(nil as UUID?)
                                ForEach(serviceStore.services) { service in
                                    Text(service.name).tag(Optional(service.id))
                                }
                            }
                        }

                        TextField("模型", text: $translationModel, prompt: Text("例如 gpt-4o-mini"))

                        LanguagePicker(title: "目标语言", selection: $targetLanguage)

                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showAdvancedTranslationOptions.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: showAdvancedTranslationOptions ? "chevron.down" : "chevron.right")
                                    .font(.caption2.bold())
                                Text("高级选项")
                                    .font(.subheadline)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)

                        if showAdvancedTranslationOptions {
                            TextField("每批字幕数", value: $translationBatchSize, format: .number)

                            LabeledContent {
                                VStack(alignment: .trailing, spacing: 4) {
                                    TextEditor(text: $translationSystemPrompt)
                                        .font(.callout)
                                        .frame(minHeight: 75)
                                        .padding(4)
                                        .background(Color.voxlineTextBackground, in: .rect(cornerRadius: 6))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                                        )

                                    Button("恢复默认") {
                                        translationSystemPrompt = TranslationSettings.defaultSystemPrompt
                                    }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                                }
                            } label: {
                                Text("系统提示词")
                            }
                        }
                    }
                }
            }

            Section("导出选项") {
                Toggle("导出原文字幕 (.source.srt)", isOn: Binding(
                    get: { outputs.contains(.source) },
                    set: { if $0 { outputs.insert(.source) } else { outputs.remove(.source) } }
                ))

                Toggle("导出译文字幕 (.translation.srt)", isOn: Binding(
                    get: { outputs.contains(.translation) },
                    set: { if $0 { outputs.insert(.translation) } else { outputs.remove(.translation) } }
                ))
                .disabled(!translates)

                Toggle("导出双语字幕 (.bilingual.srt)", isOn: Binding(
                    get: { outputs.contains(.bilingual) },
                    set: { if $0 { outputs.insert(.bilingual) } else { outputs.remove(.bilingual) } }
                ))
                .disabled(!translates)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Bottom Action Bar
    private var bottomActionBar: some View {
        HStack(spacing: 12) {
            if let blockReason = preflightBlockReason {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(blockReason).font(.caption).foregroundStyle(.orange)
                }
            } else {
                let totalCount = existingItems.count + candidates.filter({ $0.error == nil }).count
                Text("共 \(totalCount) 个媒体文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("取消") {
                importTask?.cancel()
                saveTask?.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isSaving)

            Button(originalTask.startedAt == nil ? "保存草稿" : "保存参数") {
                saveTask = Task { await commitTask() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isInspecting || isSaving || preflightBlockReason != nil)
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
        if translates && translationEngine == .api {
            if serviceStore.isLoading || serviceStore.isSaving { return "翻译服务配置正在读取或保存。" }
            if let error = serviceStore.errorMessage { return error }
            if selectedServiceID == nil || serviceStore.services.isEmpty {
                return "开启翻译时需选择已配置的翻译服务。"
            }
            if translationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "翻译模型名称不能为空。"
            }
        }
        return nil
    }

    private func commitTask(discardingTranslations: Bool = false) async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let transcription = TranscriptionSettings(
                provider: originalTask.parameters.transcription.provider, modelID: modelID,
                languageMode: languageMode,
                languageCode: languageMode == .specified ? languageCode : nil, cloud: originalTask.parameters.transcription.cloud
            )

            var translation: TranslationSettings?
            if translates && translationEngine == .apple {
                _ = try await AppleTranslationCoordinator.languagePair(sourceID: appleSourceLanguage, targetID: targetLanguage)
                translation = try TranslationSettings(appleSourceLanguage: appleSourceLanguage,
                                                      targetLanguage: targetLanguage, batchSize: appleBatchSize)
            } else if translates {
                guard let serviceID = selectedServiceID,
                      let service = serviceStore.services.first(where: { $0.id == serviceID }) else {
                    throw TaskValidationError.unconfiguredTranslationService
                }
                translation = try TranslationSettings(
                    baseURL: service.baseURL,
                    modelID: translationModel,
                    targetLanguage: targetLanguage,
                    serviceID: serviceID,
                    batchSize: translationBatchSize, systemPrompt: translationSystemPrompt
                )
            }

            var updated = originalTask
            updated.title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if updated.title.isEmpty { updated.title = "未命名任务" }

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
            let effectiveOutputs: [SRTOutputKind] = translation == nil ? [.source] : [.source, .translation, .bilingual].filter { outputs.contains($0) }
            try updated.updateParameters(TaskParameters(
                transcription: transcription, translation: translation,
                srtOutputs: effectiveOutputs.isEmpty ? [.source] : effectiveOutputs
            ), discardingTranslations: discardingTranslations)
            try updated.validate()

            for (item, inspection, trackID) in addedBookmarkPairs {
                do {
                    let access = inspection.url.startAccessingSecurityScopedResource()
                    defer { if access { inspection.url.stopAccessingSecurityScopedResource() } }

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
        } catch TaskValidationError.translationReplacementRequired {
            confirmTranslationReplacement = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

