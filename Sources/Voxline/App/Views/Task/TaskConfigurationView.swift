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
    @State private var transcriptionProvider: TranscriptionSettings.Provider
    @State private var selectedCloudServiceID: UUID?
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
    @State private var showCloudTranscriptionSettings = false

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var iosActiveTab = 0
    #endif

    private let inspector = MediaInspector.shared
    private let modelManager = ModelManager.shared
    private let serviceStore = TranslationServiceStore.shared
    private let cloudStore = CloudTranscriptionServiceStore.shared
    @State private var originalTask: ProcessingTask

    public init(task: Binding<ProcessingTask>, onCommit: ((ProcessingTask) throws -> Void)? = nil) {
        _task = task
        self.onCommit = onCommit
        let value = task.wrappedValue
        _originalTask = State(initialValue: value)
        _draftTitle = State(initialValue: value.title)
        _transcriptionProvider = State(initialValue: value.parameters.transcription.provider)
        _selectedCloudServiceID = State(initialValue: value.parameters.transcription.cloud?.serviceID)
        _modelID = State(initialValue: value.parameters.transcription.provider == .whisperKit
            ? value.parameters.transcription.modelID : TranscriptionSettings.whisperKitBaseline.modelID)
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
                    .navigationTitle(String(localized: "模型管理", bundle: appLocalizationBundle))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "完成", bundle: appLocalizationBundle)) { showModelManager = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showTranslationSettings) {
            NavigationStack {
                TranslationServicesSettingsView()
                    .navigationTitle(String(localized: "翻译服务", bundle: appLocalizationBundle))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "完成", bundle: appLocalizationBundle)) {
                                showTranslationSettings = false
                                if selectedServiceID == nil, let first = serviceStore.services.first {
                                    selectedServiceID = first.id
                                }
                            }
                        }
                    }
            }
        }
        .sheet(isPresented: $showCloudTranscriptionSettings) {
            NavigationStack {
                CloudTranscriptionServicesSettingsView(referencedSettings: originalTask.parameters.transcription)
                    .navigationTitle(String(localized: "云端转写服务", bundle: appLocalizationBundle))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "完成", bundle: appLocalizationBundle)) {
                                showCloudTranscriptionSettings = false
                                if selectedCloudServiceID == nil, let first = cloudStore.services.first {
                                    selectedCloudServiceID = first.id
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
            if enabled, selectedServiceID == nil, let first = serviceStore.services.first {
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
        .confirmationDialog(String(localized: "更换目标语言？", bundle: appLocalizationBundle), isPresented: $confirmTranslationReplacement, titleVisibility: .visible) {
            Button(String(localized: "清除现有译文并保存", bundle: appLocalizationBundle), role: .destructive) {
                saveTask = Task { await commitTask(discardingTranslations: true) }
            }
            Button(String(localized: "取消", bundle: appLocalizationBundle), role: .cancel) {}
        } message: {
            Text(String(localized: "现有译文将清除。", bundle: appLocalizationBundle))
        }
        .onDisappear {
            importTask?.cancel()
            saveTask?.cancel()
        }
        .onAppear {
            if translates && selectedServiceID == nil {
                selectedServiceID = serviceStore.services.first?.id
            }
            if transcriptionProvider == .openAICompatible && selectedCloudServiceID == nil {
                selectedCloudServiceID = cloudStore.services.first?.id
            }
        }
        .onChange(of: transcriptionProvider) { _, newProvider in
            if newProvider == .openAICompatible {
                if selectedCloudServiceID == nil {
                    selectedCloudServiceID = cloudStore.services.first?.id
                }
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
                            Text(String(localized: "媒体 (\(totalCount))", bundle: appLocalizationBundle)).tag(0)
                            Text(String(localized: "参数", bundle: appLocalizationBundle)).tag(1)
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
            .navigationTitle(originalTask.items.isEmpty ? String(localized: "新建任务", bundle: appLocalizationBundle) : String(localized: "任务准备", bundle: appLocalizationBundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消", bundle: appLocalizationBundle)) {
                        importTask?.cancel()
                        saveTask?.cancel()
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(originalTask.startedAt == nil ? String(localized: "保存任务", bundle: appLocalizationBundle) : String(localized: "保存参数", bundle: appLocalizationBundle)) {
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

            Text(originalTask.items.isEmpty ? String(localized: "新建任务", bundle: appLocalizationBundle) : String(localized: "任务准备", bundle: appLocalizationBundle))
                .font(.headline)

            Spacer()
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
                Text(String(localized: "媒体列表", bundle: appLocalizationBundle))
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
                    Label(String(localized: "添加…", bundle: appLocalizationBundle), systemImage: "plus")
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
                            Text(String(localized: "添加音视频媒体文件", bundle: appLocalizationBundle))
                                .font(.callout.weight(.medium))
                            Text(String(localized: "支持 MP4, MOV, M4V, M4A, MP3, WAV", bundle: appLocalizationBundle))
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
                                Text(item.media == nil ? String(localized: "未关联", bundle: appLocalizationBundle) : item.status.label)
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
                            Text(String(localized: "正在读取轨道信息…", bundle: appLocalizationBundle)).font(.caption).foregroundStyle(.secondary)
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
                            Text(cand.kind == .video ? String(localized: "视频", bundle: appLocalizationBundle) : String(localized: "音频", bundle: appLocalizationBundle))
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
                        Text(String(localized: "解析中…", bundle: appLocalizationBundle)).font(.caption2).foregroundStyle(.secondary)
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
                        Text(String(localized: "选择转写音轨：", bundle: appLocalizationBundle))
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

                                    Text(String(localized: "音轨 \(track.id)", bundle: appLocalizationBundle))
                                        .font(.caption.monospacedDigit().bold())

                                    Text(track.language ?? String(localized: "未知语言", bundle: appLocalizationBundle))
                                        .font(.caption)

                                    Spacer()

                                    Text(track.isDecodable ? String(localized: "可解码", bundle: appLocalizationBundle) : String(localized: "无法解码", bundle: appLocalizationBundle))
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
                    Text(String(localized: "请选择转写音轨", bundle: appLocalizationBundle))
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
            Section(String(localized: "基本信息", bundle: appLocalizationBundle)) {
                TextField(String(localized: "任务名称", bundle: appLocalizationBundle), text: $draftTitle, prompt: Text(String(localized: "输入任务名称", bundle: appLocalizationBundle)))
            }

            Section(String(localized: "语音转写", bundle: appLocalizationBundle)) {
                Picker(String(localized: "转写方式", bundle: appLocalizationBundle), selection: $transcriptionProvider) {
                    Text(String(localized: "本地 WhisperKit", bundle: appLocalizationBundle)).tag(TranscriptionSettings.Provider.whisperKit)
                    Text(String(localized: "云端 OpenAI 兼容", bundle: appLocalizationBundle)).tag(TranscriptionSettings.Provider.openAICompatible)
                }

                if transcriptionProvider == .whisperKit {
                    Picker(String(localized: "转写模型", bundle: appLocalizationBundle), selection: $modelID) {
                        if !ModelManager.availableModels.contains(where: { $0.id == modelID }) {
                            Text(String(localized: "未收录：\(modelID)", bundle: appLocalizationBundle)).tag(modelID)
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
                                Text(String(localized: "已就绪", bundle: appLocalizationBundle)).foregroundStyle(.green)
                            case .downloading, .checking:
                                ProgressView().controlSize(.mini)
                                Text(String(localized: "下载中…", bundle: appLocalizationBundle)).foregroundStyle(.blue)
                            case .notDownloaded, .cancelled:
                                Text(String(localized: "未下载", bundle: appLocalizationBundle)).foregroundStyle(.secondary)
                                Button(String(localized: "下载", bundle: appLocalizationBundle)) { modelManager.download(modelID: modelID) }
                                    .buttonStyle(.borderless)
                            case .failed, .corrupted:
                                Text(String(localized: "异常", bundle: appLocalizationBundle)).foregroundStyle(.red)
                            case .loading, .cancelling:
                                ProgressView().controlSize(.mini)
                            }
                        }
                        .font(.caption)

                        Spacer()

                        Button(String(localized: "管理模型", bundle: appLocalizationBundle)) {
                            showModelManager = true
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }

                    Picker(String(localized: "原文语言", bundle: appLocalizationBundle), selection: $languageMode) {
                        Text(String(localized: "自动识别", bundle: appLocalizationBundle)).tag(TranscriptionSettings.LanguageMode.automatic)
                        Text(String(localized: "指定语言", bundle: appLocalizationBundle)).tag(TranscriptionSettings.LanguageMode.specified)
                    }

                    if languageMode == .specified {
                        LanguagePicker(title: String(localized: "语言", bundle: appLocalizationBundle), selection: $languageCode, identifiers: WhisperKitLanguages.codes)
                    }
                } else {
                    // 云端 OpenAI 兼容
                    if cloudStore.services.isEmpty {
                        HStack {
                            Text(String(localized: "尚未配置云端转写服务", bundle: appLocalizationBundle))
                                .font(.caption).foregroundStyle(.orange)
                            Spacer()
                            Button(String(localized: "去配置…", bundle: appLocalizationBundle)) {
                                showCloudTranscriptionSettings = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    } else {
                        Picker(String(localized: "转写服务", bundle: appLocalizationBundle), selection: $selectedCloudServiceID) {
                            Text(String(localized: "请选择服务", bundle: appLocalizationBundle)).tag(nil as UUID?)
                            ForEach(cloudStore.services) { service in
                                Text(service.name).tag(Optional(service.id))
                            }
                        }

                        if let serviceID = selectedCloudServiceID, let service = cloudStore.services.first(where: { $0.id == serviceID }) {
                            HStack {
                                Text(String(localized: "API 地址", bundle: appLocalizationBundle))
                                Spacer()
                                Text((selectedCloudServiceID == originalTask.parameters.transcription.cloud?.serviceID
                                      ? originalTask.parameters.transcription.cloud?.baseURL ?? service.baseURL : service.baseURL).absoluteString)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .font(.caption)
                        }
                    }

                    HStack {
                        Text(String(localized: "服务模型", bundle: appLocalizationBundle))
                        Spacer()
                        let serviceModel = selectedCloudServiceID != nil && selectedCloudServiceID == originalTask.parameters.transcription.cloud?.serviceID
                            ? originalTask.parameters.transcription.modelID
                            : cloudStore.services.first(where: { $0.id == selectedCloudServiceID })?.modelID
                        Text(serviceModel ?? String(localized: "未选择", bundle: appLocalizationBundle))
                            .foregroundStyle(.secondary)
                    }

                    Picker(String(localized: "原文语言", bundle: appLocalizationBundle), selection: $languageMode) {
                        Text(String(localized: "自动识别", bundle: appLocalizationBundle)).tag(TranscriptionSettings.LanguageMode.automatic)
                        Text(String(localized: "指定语言", bundle: appLocalizationBundle)).tag(TranscriptionSettings.LanguageMode.specified)
                    }

                    if languageMode == .specified {
                        let selectedProtocol = selectedCloudServiceID == originalTask.parameters.transcription.cloud?.serviceID
                            ? originalTask.parameters.transcription.cloud?.protocolKind ?? .audioTranscriptions
                            : selectedCloudServiceID.flatMap { id in cloudStore.services.first(where: { $0.id == id })?.protocolKind } ?? .audioTranscriptions
                        LanguagePicker(title: String(localized: "语言代码", bundle: appLocalizationBundle), selection: $languageCode, identifiers: cloudLanguageIdentifiers(for: selectedProtocol))
                    }
                }
            }

            Section(String(localized: "字幕翻译", bundle: appLocalizationBundle)) {
                Toggle(String(localized: "启用字幕翻译", bundle: appLocalizationBundle), isOn: $translates)

                if translates {
                    Picker(String(localized: "翻译服务", bundle: appLocalizationBundle), selection: $translationEngine) {
                        Text(String(localized: "OpenAI 接口", bundle: appLocalizationBundle)).tag(TranslationEngineChoice.api)
                        Text(String(localized: "Apple Translation (本机)", bundle: appLocalizationBundle)).tag(TranslationEngineChoice.apple)
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
                                Text(String(localized: "尚未配置翻译服务", bundle: appLocalizationBundle))
                                    .font(.caption).foregroundStyle(.orange)
                                Spacer()
                                Button(String(localized: "去配置…", bundle: appLocalizationBundle)) {
                                    showTranslationSettings = true
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        } else {
                            Picker(String(localized: "服务提供商", bundle: appLocalizationBundle), selection: $selectedServiceID) {
                                Text(String(localized: "请选择服务", bundle: appLocalizationBundle)).tag(nil as UUID?)
                                ForEach(serviceStore.services) { service in
                                    Text(service.name).tag(Optional(service.id))
                                }
                            }
                        }

                        TextField(String(localized: "模型", bundle: appLocalizationBundle), text: $translationModel, prompt: Text(String(localized: "例如 gpt-4o-mini", bundle: appLocalizationBundle)))

                        LanguagePicker(title: String(localized: "目标语言", bundle: appLocalizationBundle), selection: $targetLanguage)

                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showAdvancedTranslationOptions.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: showAdvancedTranslationOptions ? "chevron.down" : "chevron.right")
                                    .font(.caption2.bold())
                                Text(String(localized: "高级选项", bundle: appLocalizationBundle))
                                    .font(.subheadline)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)

                        if showAdvancedTranslationOptions {
                            TextField(String(localized: "每批字幕数", bundle: appLocalizationBundle), value: $translationBatchSize, format: .number)

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

                                    HStack {
                                        Spacer()
                                        Button(String(localized: "恢复默认", bundle: appLocalizationBundle)) {
                                            translationSystemPrompt = TranslationSettings.defaultSystemPrompt
                                        }
                                        .buttonStyle(.borderless)
                                        .font(.caption)
                                    }
                                }
                            } label: {
                                Text(String(localized: "系统提示词", bundle: appLocalizationBundle))
                            }
                        }
                    }
                }
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
                Text(String(localized: "共 \(totalCount) 个媒体文件", bundle: appLocalizationBundle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(String(localized: "取消", bundle: appLocalizationBundle)) {
                importTask?.cancel()
                saveTask?.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isSaving)

            Button(originalTask.startedAt == nil ? String(localized: "保存草稿", bundle: appLocalizationBundle) : String(localized: "保存参数", bundle: appLocalizationBundle)) {
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
            return String(localized: "请先在左侧添加音视频。", bundle: appLocalizationBundle)
        }
        for candidate in candidates where candidate.error == nil {
            if candidate.inspection != nil && candidate.trackID == nil {
                return String(localized: "媒体“\(candidate.url.lastPathComponent)”尚未选择音轨。", bundle: appLocalizationBundle)
            }
        }
        if transcriptionProvider == .openAICompatible, selectedCloudServiceID == nil || selectedCloudServiceID != originalTask.parameters.transcription.cloud?.serviceID {
            if cloudStore.isLoading || cloudStore.isSaving { return String(localized: "云端转写服务配置正在读取或保存。", bundle: appLocalizationBundle) }
            if let error = cloudStore.errorMessage { return error }
            if !cloudStore.services.contains(where: { $0.id == selectedCloudServiceID }) {
                return String(localized: "开启云端转写需选择已配置的转写服务。", bundle: appLocalizationBundle)
            }
            if let service = cloudStore.services.first(where: { $0.id == selectedCloudServiceID }) {
                do {
                    _ = try service.settings(languageCode: languageMode == .specified
                        ? languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : nil)
                } catch { return error.localizedDescription }
            }
        }
        if translates && translationEngine == .api {
            if serviceStore.isLoading || serviceStore.isSaving { return String(localized: "翻译服务配置正在读取或保存。", bundle: appLocalizationBundle) }
            if let error = serviceStore.errorMessage { return error }
            if selectedServiceID == nil || serviceStore.services.isEmpty {
                return String(localized: "开启翻译时需选择已配置的翻译服务。", bundle: appLocalizationBundle)
            }
            if translationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return String(localized: "翻译模型名称不能为空。", bundle: appLocalizationBundle)
            }
        }
        return nil
    }

    private func commitTask(discardingTranslations: Bool = false) async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let transcription: TranscriptionSettings
            if transcriptionProvider == .whisperKit {
                transcription = TranscriptionSettings(
                    provider: .whisperKit,
                    modelID: modelID,
                    languageMode: languageMode,
                    languageCode: languageMode == .specified ? languageCode : nil,
                    cloud: nil
                )
            } else if let cloud = originalTask.parameters.transcription.cloud, selectedCloudServiceID == cloud.serviceID {
                transcription = TranscriptionSettings(provider: .openAICompatible,
                    modelID: originalTask.parameters.transcription.modelID, languageMode: languageMode,
                    languageCode: languageMode == .specified ? languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : nil,
                    cloud: cloud)
            } else {
                guard let serviceID = selectedCloudServiceID,
                      let service = cloudStore.services.first(where: { $0.id == serviceID }) else {
                    throw CloudTranscriptionError.unconfiguredService
                }
                transcription = try service.settings(languageCode: languageMode == .specified ? languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : nil)
            }

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
            if updated.title.isEmpty { updated.title = String(localized: "未命名任务", bundle: appLocalizationBundle) }

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
                    errorMessage = String(localized: "\(candidate.url.lastPathComponent)：请先选择转写音轨。", bundle: appLocalizationBundle)
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
            try updated.updateParameters(TaskParameters(
                transcription: transcription, translation: translation
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

    private func cloudLanguageIdentifiers(for proto: CloudTranscriptionProtocol) -> [String] {
        let allowedRange: ClosedRange<Int> = proto == .qwenAudioChat ? 2...3 : 2...2
        let baseCodes = Locale.LanguageCode.isoLanguageCodes.map(\.identifier)
        let extraCodes = proto == .qwenAudioChat ? ["yue", "fil"] : []
        let filtered = (baseCodes + extraCodes).filter { code in
            allowedRange.contains(code.count) && code.allSatisfy({ $0.isASCII && $0.isLetter })
        }
        return Array(Set(filtered)).sorted()
    }
}

