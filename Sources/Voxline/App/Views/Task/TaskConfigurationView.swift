import VoxlineTranslation
import VoxlineWhisperKit
import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore
import VoxlineMedia

public struct TaskConfigurationView: View {
    @Binding var task: ProcessingTask
    let onCommit: (ProcessingTask) throws -> Void
    @State private var session: TaskConfigurationSession
    @Environment(\.dismiss) private var dismiss

    @State private var showAdvancedTranslationOptions = false

    @State private var dropTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?
    @State private var showMediaImporter = false
    @State private var confirmTranslationReplacement = false
    @State private var showModelManager = false
    @State private var showTranslationSettings = false
    @State private var showCloudTranscriptionSettings = false
    @State private var isDropTargeted = false

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var iosActiveTab = 0
    #endif

    private let modelManager = ModelManager.shared
    private var serviceStore: TranslationServiceStore { session.serviceStore }
    private var cloudStore: CloudTranscriptionServiceStore { session.cloudStore }

    public init(task: Binding<ProcessingTask>, onCommit: @escaping (ProcessingTask) throws -> Void) {
        _task = task
        self.onCommit = onCommit
        _session = State(initialValue: TaskConfigurationSession(task: task.wrappedValue))
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
                                if session.selectedServiceID == nil, let first = serviceStore.services.first {
                                    session.selectedServiceID = first.id
                                }
                            }
                        }
                    }
            }
        }
        .sheet(isPresented: $showCloudTranscriptionSettings) {
            NavigationStack {
                CloudTranscriptionServicesSettingsView(referencedSettings: session.originalTask.parameters.transcription)
                    .navigationTitle(String(localized: "云端转写服务", bundle: appLocalizationBundle))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "完成", bundle: appLocalizationBundle)) {
                                showCloudTranscriptionSettings = false
                                if session.selectedCloudServiceID == nil, let first = cloudStore.services.first {
                                    session.selectedCloudServiceID = first.id
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
            case .failure(let error): session.errorMessage = error.localizedDescription
            case .success(let urls):
                session.importMediaURLs(urls)
            }
        }
        .onChange(of: session.translates) { _, enabled in
            if enabled, session.selectedServiceID == nil, let first = serviceStore.services.first {
                session.selectedServiceID = first.id
                session.translationModel = first.modelID
            }
        }
        .onChange(of: session.selectedServiceID) { _, id in
            if let service = serviceStore.services.first(where: { $0.id == id }) {
                session.translationModel = service.modelID
                session.translationBatchSize = service.batchSize
                session.translationSystemPrompt = service.systemPrompt
            }
        }
        .onChange(of: serviceStore.services) { _, services in
            if let service = services.first(where: { $0.id == session.selectedServiceID }) {
                session.translationBatchSize = service.batchSize
                session.translationSystemPrompt = service.systemPrompt
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
            dropTask?.cancel()
            session.cancelImport()
            saveTask?.cancel()
        }
        .onAppear {
            if session.translates && session.selectedServiceID == nil {
                session.selectedServiceID = serviceStore.services.first?.id
            }
            if session.transcriptionProvider == .openAICompatible && session.selectedCloudServiceID == nil {
                session.selectedCloudServiceID = cloudStore.services.first?.id
            }
        }
        .onChange(of: session.transcriptionProvider) { _, newProvider in
            if newProvider == .openAICompatible {
                if session.selectedCloudServiceID == nil {
                    session.selectedCloudServiceID = cloudStore.services.first?.id
                }
            }
        }
    }

    #if os(macOS)
    private var macosBody: some View {
        VStack(spacing: 0) {
            sheetHeaderBar
            Divider()

            if let errorMessage = session.errorMessage {
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
                if let errorMessage = session.errorMessage {
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
                        let totalCount = session.existingItems.count + session.candidates.count
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
            .navigationTitle(session.originalTask.items.isEmpty ? String(localized: "新建任务", bundle: appLocalizationBundle) : String(localized: "任务准备", bundle: appLocalizationBundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消", bundle: appLocalizationBundle)) {
                        session.cancelImport()
                        saveTask?.cancel()
                        dismiss()
                    }
                    .disabled(session.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(session.originalTask.startedAt == nil ? String(localized: "保存任务", bundle: appLocalizationBundle) : String(localized: "保存参数", bundle: appLocalizationBundle)) {
                        saveTask = Task { await commitTask() }
                    }
                    .bold()
                    .disabled(session.isInspecting || session.isSaving || session.preflightBlockReason != nil)
                }
            }
        }
    }
    #endif

    // MARK: - Sheet Header Bar
    #if os(macOS)
    private var sheetHeaderBar: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.24), lineWidth: 0.8)
                    )
                Image(systemName: "film.stack")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 28, height: 28)

            Text(session.originalTask.items.isEmpty ? String(localized: "新建任务", bundle: appLocalizationBundle) : String(localized: "任务准备", bundle: appLocalizationBundle))
                .font(.system(size: 14, weight: .semibold))

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background {
            Color(nsColor: .windowBackgroundColor).opacity(0.7)
                .background(.regularMaterial)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.4))
                .frame(height: 1)
        }
    }

    #endif

    // MARK: - Left: Media Import & Tracks Panel
    private var fcpMediaImportPane: some View {
        VStack(spacing: 0) {
            // Pane Sub-header
            HStack {
                let totalCount = session.existingItems.count + session.candidates.count
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
                .disabled(session.isInspecting)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.voxlineControlBackground)

            Divider()

            // Media list
            ScrollView {
                VStack(spacing: 10) {
                    if session.existingItems.isEmpty && session.candidates.isEmpty {
                        emptyMediaDropZone
                    }

                    // Existing Items List
                    ForEach(Array(session.existingItems.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 10) {
                            Image(systemName: item.kind == .video ? "film" : "waveform")
                                .font(.title3)
                                .foregroundStyle(item.kind == .video ? .blue : .purple)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.system(size: 13, weight: .semibold))
                                Text(item.media == nil ? String(localized: "未关联", bundle: appLocalizationBundle) : item.status.label)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()

                            Button { session.existingItems.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }
                                .buttonStyle(.plain).disabled(index == 0)
                            Button { session.existingItems.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }
                                .buttonStyle(.plain).disabled(index == session.existingItems.count - 1)
                            Button { session.existingItems.remove(at: index) } label: { Image(systemName: "trash").foregroundStyle(.red) }
                                .buttonStyle(.plain)
                        }
                        .padding(10)
                        .background(Color.voxlineControlBackground, in: .rect(cornerRadius: 8))
                    }

                    // Newly selected session.candidates
                    ForEach(Array(session.candidates.enumerated()), id: \.element.id) { index, _ in
                        candidateCard(index: index, candidate: $session.candidates[index])
                    }

                    if session.isInspecting {
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
    private func candidateCard(index: Int, candidate: Binding<TaskConfigurationSession.ImportCandidate>) -> some View {
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
                            Text(TimecodeFormatter.formatDuration(seconds: sec))
                                .font(.caption2.monospacedDigit())
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
                    session.candidates.swapAt(index, index - 1)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.plain)
                .disabled(index == 0)

                Button {
                    session.candidates.swapAt(index, index + 1)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .buttonStyle(.plain)
                .disabled(index == session.candidates.count - 1)

                Button {
                    session.candidates.removeAll { $0.id == cand.id }
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
                TextField(String(localized: "任务名称", bundle: appLocalizationBundle), text: $session.draftTitle, prompt: Text(String(localized: "输入任务名称", bundle: appLocalizationBundle)))
            }

            Section(String(localized: "语音转写", bundle: appLocalizationBundle)) {
                if !session.requiresSpeechRecognition {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(String(localized: "原文字幕已就绪", bundle: appLocalizationBundle))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    Picker(String(localized: "转写方式", bundle: appLocalizationBundle), selection: $session.transcriptionProvider) {
                        Text(String(localized: "本地 WhisperKit", bundle: appLocalizationBundle)).tag(TranscriptionSettings.Provider.whisperKit)
                        Text(String(localized: "云端 OpenAI 兼容", bundle: appLocalizationBundle)).tag(TranscriptionSettings.Provider.openAICompatible)
                    }

                    if session.transcriptionProvider == .whisperKit {
                        Picker(String(localized: "转写模型", bundle: appLocalizationBundle), selection: $session.modelID) {
                            if !ModelManager.availableModels.contains(where: { $0.id == session.modelID }) {
                                Text(String(localized: "未收录：\(session.modelID)", bundle: appLocalizationBundle)).tag(session.modelID)
                            }
                            ForEach(ModelManager.availableModels) { model in
                                Text(model.name).tag(model.id)
                            }
                        }

                        HStack {
                            let status = modelManager.status(for: session.modelID)
                            HStack(spacing: 5) {
                                switch status {
                                case .ready:
                                    Circle().fill(Color.green).frame(width: 7, height: 7)
                                    Text(String(localized: "已就绪", bundle: appLocalizationBundle)).foregroundStyle(.green)
                                case .downloading, .checking:
                                    ProgressView().controlSize(.mini)
                                    Text(String(localized: "下载中…", bundle: appLocalizationBundle)).foregroundStyle(.blue)
                                case .notDownloaded, .cancelled:
                                    Text(String(localized: "未下载", bundle: appLocalizationBundle)).foregroundStyle(.secondary)
                                    Button(String(localized: "下载", bundle: appLocalizationBundle)) { modelManager.download(modelID: session.modelID) }
                                        .buttonStyle(.borderless)
                                case .failed, .corrupted:
                                    Text(String(localized: "异常", bundle: appLocalizationBundle)).foregroundStyle(.red)
                                case .cancelling:
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

                        Picker(String(localized: "原文语言", bundle: appLocalizationBundle), selection: $session.languageMode) {
                            Text(String(localized: "自动识别", bundle: appLocalizationBundle)).tag(TranscriptionSettings.LanguageMode.automatic)
                            Text(String(localized: "指定语言", bundle: appLocalizationBundle)).tag(TranscriptionSettings.LanguageMode.specified)
                        }

                        if session.languageMode == .specified {
                            LanguagePicker(title: String(localized: "语言", bundle: appLocalizationBundle), selection: $session.languageCode, identifiers: WhisperKitLanguages.codes)
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
                            Picker(String(localized: "转写服务", bundle: appLocalizationBundle), selection: $session.selectedCloudServiceID) {
                                Text(String(localized: "请选择服务", bundle: appLocalizationBundle)).tag(nil as UUID?)
                                ForEach(cloudStore.services) { service in
                                    Text(service.name).tag(Optional(service.id))
                                }
                            }

                            if let serviceID = session.selectedCloudServiceID, let service = cloudStore.services.first(where: { $0.id == serviceID }) {
                                HStack {
                                    Text(String(localized: "API 地址", bundle: appLocalizationBundle))
                                    Spacer()
                                    Text((session.selectedCloudServiceID == session.originalTask.parameters.transcription.cloud?.serviceID
                                          ? session.originalTask.parameters.transcription.cloud?.baseURL ?? service.baseURL : service.baseURL).absoluteString)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .font(.caption)
                            }
                        }

                        HStack {
                            Text(String(localized: "服务模型", bundle: appLocalizationBundle))
                            Spacer()
                            let serviceModel = session.selectedCloudServiceID != nil && session.selectedCloudServiceID == session.originalTask.parameters.transcription.cloud?.serviceID
                                ? session.originalTask.parameters.transcription.modelID
                                : cloudStore.services.first(where: { $0.id == session.selectedCloudServiceID })?.modelID
                            Text(serviceModel ?? String(localized: "未选择", bundle: appLocalizationBundle))
                                .foregroundStyle(.secondary)
                        }

                        Picker(String(localized: "原文语言", bundle: appLocalizationBundle), selection: $session.languageMode) {
                            Text(String(localized: "自动识别", bundle: appLocalizationBundle)).tag(TranscriptionSettings.LanguageMode.automatic)
                            Text(String(localized: "指定语言", bundle: appLocalizationBundle)).tag(TranscriptionSettings.LanguageMode.specified)
                        }

                        if session.languageMode == .specified {
                            let selectedProtocol = session.selectedCloudServiceID == session.originalTask.parameters.transcription.cloud?.serviceID
                                ? session.originalTask.parameters.transcription.cloud?.protocolKind ?? .audioTranscriptions
                                : session.selectedCloudServiceID.flatMap { id in cloudStore.services.first(where: { $0.id == id })?.protocolKind } ?? .audioTranscriptions
                            LanguagePicker(title: String(localized: "语言代码", bundle: appLocalizationBundle), selection: $session.languageCode, identifiers: (selectedProtocol).languageIdentifiers)
                        }
                    }
                }
            }

            Section(String(localized: "字幕翻译", bundle: appLocalizationBundle)) {
                Toggle(String(localized: "启用字幕翻译", bundle: appLocalizationBundle), isOn: $session.translates)

                if session.translates {
                    Picker(String(localized: "翻译服务", bundle: appLocalizationBundle), selection: $session.translationEngine) {
                        Text(String(localized: "OpenAI 接口", bundle: appLocalizationBundle)).tag(TaskConfigurationSession.TranslationEngineChoice.api)
                        Text(String(localized: "Apple Translation (本机)", bundle: appLocalizationBundle)).tag(TaskConfigurationSession.TranslationEngineChoice.apple)
                    }

                    if session.translationEngine == .apple {
                        AppleTranslationLanguageSettings(
                            source: $session.appleSourceLanguage,
                            target: $session.targetLanguage,
                            batchSize: $session.appleBatchSize
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
                            Picker(String(localized: "服务提供商", bundle: appLocalizationBundle), selection: $session.selectedServiceID) {
                                Text(String(localized: "请选择服务", bundle: appLocalizationBundle)).tag(nil as UUID?)
                                ForEach(serviceStore.services) { service in
                                    Text(service.name).tag(Optional(service.id))
                                }
                            }
                        }

                        TextField(String(localized: "模型", bundle: appLocalizationBundle), text: $session.translationModel, prompt: Text(String(localized: "例如 gpt-4o-mini", bundle: appLocalizationBundle)))

                        LanguagePicker(title: String(localized: "目标语言", bundle: appLocalizationBundle), selection: $session.targetLanguage)

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
                            LabeledContent(String(localized: "每批字幕数", bundle: appLocalizationBundle)) {
                                TextField("", value: $session.translationBatchSize, format: .number)
                                    .multilineTextAlignment(.trailing)
                                    #if os(iOS)
                                    .keyboardType(.numberPad)
                                    #endif
                            }

                            LabeledContent {
                                VStack(alignment: .trailing, spacing: 4) {
                                    TextEditor(text: $session.translationSystemPrompt)
                                        .font(.callout)
                                        .scrollContentBackground(.hidden)
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
                                            session.translationSystemPrompt = TranslationSettings.defaultSystemPrompt
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
    #if os(macOS)
    private var bottomActionBar: some View {
        HStack(spacing: 12) {
            if let blockReason = session.preflightBlockReason {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(blockReason).font(.caption).foregroundStyle(.orange)
                }
            } else {
                let totalCount = session.existingItems.count + session.candidates.filter({ $0.error == nil }).count
                Text(String(localized: "共 \(totalCount) 个媒体文件", bundle: appLocalizationBundle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(String(localized: "取消", bundle: appLocalizationBundle)) {
                session.cancelImport()
                saveTask?.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(session.isSaving)

            Button(session.originalTask.startedAt == nil ? String(localized: "保存草稿", bundle: appLocalizationBundle) : String(localized: "保存参数", bundle: appLocalizationBundle)) {
                saveTask = Task { await commitTask() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(session.isInspecting || session.isSaving || session.preflightBlockReason != nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background {
            Color(nsColor: .windowBackgroundColor).opacity(0.7)
                .background(.regularMaterial)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.4))
                .frame(height: 1)
        }
    }

    #endif

    private func commitTask(discardingTranslations: Bool = false) async {
        do {
            task = try await session.commit(comparedTo: { task }, discardingTranslations: discardingTranslations, onCommit: onCommit)
            dismiss()
        } catch TaskValidationError.translationReplacementRequired {
            confirmTranslationReplacement = true
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Media Drag & Drop Zone
    private var emptyMediaDropZone: some View {
        Button {
            showMediaImporter = true
        } label: {
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            isDropTargeted
                                ? LinearGradient(colors: [Color.accentColor.opacity(0.24), Color.accentColor.opacity(0.12)], startPoint: .top, endPoint: .bottom)
                                : LinearGradient(colors: [Color.secondary.opacity(0.10), Color.secondary.opacity(0.04)], startPoint: .top, endPoint: .bottom)
                        )
                        .frame(width: 58, height: 58)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(isDropTargeted ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06), lineWidth: 1)
                        )

                    Image(systemName: isDropTargeted ? "arrow.down.circle.fill" : "waveform.badge.plus")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
                }

                VStack(spacing: 5) {
                    Text(String(localized: "拖入音视频文件", bundle: appLocalizationBundle))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isDropTargeted ? Color.accentColor : Color.primary)

                    Text(String(localized: "支持 MP4, MOV, M4V, M4A, MP3, WAV 等格式", bundle: appLocalizationBundle))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    showMediaImporter = true
                } label: {
                    Label(String(localized: "选择文件…", bundle: appLocalizationBundle), systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .padding(.top, 4)
            }
            .padding(.vertical, 36)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isDropTargeted ? Color.accentColor.opacity(0.06) : Color.secondary.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.24),
                        style: StrokeStyle(lineWidth: isDropTargeted ? 2.0 : 1.2, dash: isDropTargeted ? [] : [6, 4])
                    )
            )
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.2), value: isDropTargeted)
        }
        .buttonStyle(.plain)
        .padding(14)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDroppedProviders(providers)
        }
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        let matching = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !matching.isEmpty else { return false }
        guard dropTask == nil else {
            session.errorMessage = TaskConfigurationError.importInProgress.localizedDescription
            return false
        }

        dropTask = Task { @MainActor in
            defer { dropTask = nil }
            var urls: [URL] = []
            var failures: [String] = []
            for provider in matching {
                let result: Result<URL, any Error> = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { loadedURL, error in
                        if let error { continuation.resume(returning: .failure(error)) }
                        else if let loadedURL { continuation.resume(returning: .success(loadedURL)) }
                        else { continuation.resume(returning: .failure(CocoaError(.fileReadUnknown))) }
                    }
                }
                guard !Task.isCancelled else { return }
                switch result {
                case .success(let url): urls.append(url)
                case .failure(let error): failures.append(error.localizedDescription)
                }
            }
            if !urls.isEmpty { session.importMediaURLs(urls) }
            if !failures.isEmpty { session.errorMessage = failures.joined(separator: "\n") }
        }
        return true
    }

}
