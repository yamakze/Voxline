import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VoxlineCore
import VoxlineMedia

struct TaskConfigurationView: View {
    @Binding var task: ProcessingTask
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProcessingTask
    @State private var modelID: String
    @State private var languageMode: TranscriptionSettings.LanguageMode
    @State private var languageCode: String
    @State private var translates: Bool
    @State private var serviceURL: String
    @State private var translationModel: String
    @State private var targetLanguage: String
    @State private var outputs: Set<SRTOutputKind>
    @State private var candidates: [ImportCandidate] = []
    @State private var isInspecting = false
    @State private var importTask: Task<Void, Never>?
    @State private var isSaving = false
    @State private var error: String?
    private let inspector = MediaInspector()
    private let originalTask: ProcessingTask

    init(task: Binding<ProcessingTask>) {
        _task = task
        let value = task.wrappedValue
        originalTask = value
        _draft = State(initialValue: value)
        _modelID = State(initialValue: value.parameters.transcription.modelID)
        _languageMode = State(initialValue: value.parameters.transcription.languageMode)
        _languageCode = State(initialValue: value.parameters.transcription.languageCode ?? "en")
        _translates = State(initialValue: value.parameters.translation != nil)
        _serviceURL = State(initialValue: value.parameters.translation?.baseURL.absoluteString ?? "")
        _translationModel = State(initialValue: value.parameters.translation?.modelID ?? "")
        _targetLanguage = State(initialValue: value.parameters.translation?.targetLanguage ?? "zh-Hans")
        _outputs = State(initialValue: Set(value.parameters.srtOutputs))
    }

    private struct ImportCandidate: Identifiable {
        let id = UUID()
        let url: URL
        var inspection: MediaInspection?
        var trackID: Int32?
        var error: String?
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("任务准备").font(.title2.bold())
                Spacer()
                Text("开始处理前可修改").foregroundStyle(.secondary)
            }.padding(24)
            Divider()
            Form {
                Section("任务") { TextField("名称", text: $draft.title) }
                Section("本地媒体 · 按列表顺序处理") {
                    ForEach(Array(draft.items.enumerated()), id: \.element.id) { index, item in
                        HStack {
                            Label(item.title, systemImage: item.kind == .video ? "film" : "waveform")
                            Spacer()
                            Text(item.media == nil ? "待关联" : item.status.label).foregroundStyle(.secondary)
                            Button("上移", systemImage: "arrow.up") { draft.items.swapAt(index, index - 1) }
                                .labelStyle(.iconOnly).disabled(index == 0)
                            if item.cues.isEmpty, item.status == .pending {
                                Button("移除", systemImage: "minus.circle") { draft.items.remove(at: index) }
                                    .labelStyle(.iconOnly)
                            }
                        }
                    }
                    ForEach($candidates) { $candidate in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(candidate.url.lastPathComponent, systemImage: "film")
                                Spacer()
                                Button("移除", systemImage: "minus.circle") {
                                    candidates.removeAll { $0.id == candidate.id }
                                }.labelStyle(.iconOnly).disabled(isInspecting)
                            }
                            if let inspection = candidate.inspection {
                                Text(String(format: "%.1f 秒 · %.1f MiB", Double(inspection.durationMilliseconds) / 1000,
                                            Double(inspection.byteCount) / 1_048_576)).foregroundStyle(.secondary)
                                Picker("转写音轨", selection: $candidate.trackID) {
                                    Text("请选择音轨").tag(nil as Int32?)
                                    ForEach(inspection.audioTracks) { track in
                                        Text("轨 \(track.id) · \(track.language ?? "语言未知") · \(track.codecs.joined(separator: ", "))")
                                            .tag(Optional(track.id)).disabled(!track.isDecodable)
                                    }
                                }
                            } else if let problem = candidate.error {
                                Text(problem).foregroundStyle(.red).textSelection(.enabled)
                            } else { Text("等待媒体检查…").foregroundStyle(.secondary) }
                        }
                    }
                    Button("添加本地视频…", systemImage: "plus") { chooseVideos() }
                        .disabled(isInspecting)
                    if isInspecting { ProgressView("正在逐个检查媒体…") }
                    Text("MP4 / MOV / M4V · 文件保持在原位置。独立音频输入尚未接通。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("本次转写") {
                    TextField("WhisperKit 模型 ID", text: $modelID)
                    Picker("原文语言", selection: $languageMode) {
                        Text("自动识别").tag(TranscriptionSettings.LanguageMode.automatic)
                        Text("指定语言").tag(TranscriptionSettings.LanguageMode.specified)
                    }
                    if languageMode == .specified { TextField("语言代码（如 en）", text: $languageCode) }
                    Text("模型下载与转写尚未接通；选择模型不会表示模型已就绪。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("本次翻译") {
                    Toggle("翻译字幕", isOn: $translates)
                    if translates {
                        TextField("OpenAI 兼容服务地址", text: $serviceURL)
                        TextField("翻译模型", text: $translationModel)
                        TextField("目标语言", text: $targetLanguage)
                        Text("当前仅保存本次参数；服务配置与密钥保存尚未接通。翻译启动时，字幕文本会发送至所选服务，费用由服务商计收。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("SRT 输出内容") {
                    ForEach([SRTOutputKind.source, .translation, .bilingual], id: \.self) { kind in
                        Toggle(kind.label, isOn: Binding(get: { outputs.contains(kind) }, set: {
                            if $0 { outputs.insert(kind) } else { outputs.remove(kind) }
                        })).disabled(kind != .source && !translates)
                    }
                    Text("导出功能尚未接通；此处记录本次任务的输出选择。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    Button("取消") { importTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("保存任务准备") { Task { await saveDraft() } }
                        .keyboardShortcut(.defaultAction).disabled(isInspecting || isSaving)
                }
            }.padding(20)
        }
        .frame(width: 720, height: 760)
        .disabled(isSaving).interactiveDismissDisabled(isInspecting || isSaving)
        .onDisappear { importTask?.cancel() }
        .onChange(of: translates) { _, enabled in if !enabled { outputs = [.source] } }
    }

    private func chooseVideos() {
        guard let window = NSApp.keyWindow else {
            error = "任务窗口不可用，请重新打开任务准备。"
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, UTType(importedAs: "com.apple.m4v-video")]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "添加视频"
        panel.beginSheetModal(for: window) { response in
            panel.orderOut(nil)
            if response == .OK {
                let urls = panel.urls
                importTask = Task {
                    isInspecting = true
                    defer { isInspecting = false }
                    let additions = urls.filter { url in !candidates.contains { $0.url == url } }
                    for url in additions {
                        if Task.isCancelled { return }
                        let candidate = ImportCandidate(url: url)
                        candidates.append(candidate)
                        do {
                            let inspection = try await inspector.inspect(url)
                            guard let index = candidates.firstIndex(where: { $0.id == candidate.id }) else { continue }
                            candidates[index].inspection = inspection
                            if inspection.audioTracks.count == 1 { candidates[index].trackID = inspection.audioTracks[0].id }
                        } catch {
                            if let index = candidates.firstIndex(where: { $0.id == candidate.id }) {
                                candidates[index].error = error.localizedDescription
                            }
                        }
                    }
                }
            }
        }
    }

    /// Commit validated parameters and media together; dismissal never changes the document.
    private func saveDraft() async {
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let transcription = TranscriptionSettings(modelID: modelID, languageMode: languageMode,
                                                      languageCode: languageMode == .specified ? languageCode : nil)
            var translation: TranslationSettings?
            if translates {
                guard let url = URL(string: serviceURL) else { throw ProjectValidationError.invalidTranslationSettings }
                let previous = draft.parameters.translation
                let serviceID = previous?.baseURL == url ? previous?.serviceID : nil
                translation = try TranslationSettings(baseURL: url, modelID: translationModel,
                                                      targetLanguage: targetLanguage, serviceID: serviceID)
            }
            var updated = draft
            try updated.updateParameters(TaskParameters(transcription: transcription, translation: translation,
                                                        srtOutputs: [.source, .translation, .bilingual].filter { outputs.contains($0) }))
            var added: [(TaskMediaItem, URL)] = []
            for candidate in candidates {
                guard let inspection = candidate.inspection, let trackID = candidate.trackID else {
                    error = "\(candidate.url.lastPathComponent)：\(candidate.error ?? "请先选择转写音轨。")"
                    return
                }
                var item = TaskMediaItem(id: candidate.id, title: candidate.url.deletingPathExtension().lastPathComponent,
                                         kind: .video, source: .unassociated)
                try item.associateMedia(inspection.identity(audioTrackID: trackID))
                added.append((item, candidate.url))
            }
            updated.items.append(contentsOf: added.map(\.0))
            try updated.validate()
            for (item, url) in added {
                guard let identity = item.media else { throw TaskValidationError.unassociatedMedia(item.id) }
                try await LocalMediaStore.shared.save(projectID: item.id, identity: identity, url: url)
            }
            guard task == originalTask else { throw PreparationError.taskChanged }
            task = updated
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private enum PreparationError: LocalizedError {
        case taskChanged
        var errorDescription: String? { "任务在准备期间已发生变化，请重新打开任务准备，保留最新成果。" }
    }
}
