import SwiftUI
import VoxlineCore
import VoxlineTranslation

/// Edit an existing task without rebuilding its transcription or media preparation.
struct TaskTranslationParametersView: View {
    @State private var original: ProcessingTask
    let onCommit: (ProcessingTask, ProcessingTask) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var store = TranslationServiceStore.shared
    @State private var enabled: Bool
    @State private var apple: Bool
    @State private var serviceID: UUID?
    @State private var model: String
    @State private var source: String
    @State private var target: String
    @State private var batchSize: Int
    @State private var prompt: String
    @State private var outputs: Set<SRTOutputKind>
    @State private var errorMessage: String?
    @State private var replacement = false
    @State private var isSaving = false

    init(task: ProcessingTask, onCommit: @escaping (ProcessingTask, ProcessingTask) throws -> Void) {
        _original = State(initialValue: task)
        self.onCommit = onCommit
        _enabled = State(initialValue: task.parameters.translation != nil)
        if case .appleTranslation(let source) = task.parameters.translation?.engine {
            _apple = State(initialValue: true)
            _source = State(initialValue: source)
        } else {
            _apple = State(initialValue: false)
            _source = State(initialValue: "en")
        }
        _serviceID = State(initialValue: task.parameters.translation?.api?.serviceID)
        _model = State(initialValue: task.parameters.translation?.api?.modelID ?? "")
        _target = State(initialValue: task.parameters.translation?.targetLanguage ?? "zh-Hans")
        _batchSize = State(initialValue: task.parameters.translation?.batchSize ?? TranslationSettings.defaultBatchSize)
        _prompt = State(initialValue: task.parameters.translation?.api?.systemPrompt ?? TranslationSettings.defaultSystemPrompt)
        _outputs = State(initialValue: Set(task.parameters.srtOutputs))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("转写") {
                    Text(original.parameters.transcription.modelID)
                    Text("已有转写和原文保持；此处调整翻译及导出参数。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("字幕翻译") {
                    Toggle("启用翻译", isOn: $enabled)
                    if enabled {
                        Picker("引擎", selection: $apple) {
                            Text("OpenAI 兼容接口").tag(false)
                            Text("Apple 本机翻译").tag(true)
                        }
                        if apple {
                            AppleTranslationLanguageSettings(source: $source, target: $target, batchSize: $batchSize)
                        } else {
                            Picker("本机服务", selection: $serviceID) {
                                Text("请选择服务").tag(nil as UUID?)
                                if let serviceID, !store.services.contains(where: { $0.id == serviceID }) {
                                    Text("原服务未在此设备配置").tag(Optional(serviceID))
                                }
                                ForEach(store.services) { service in Text(service.name).tag(Optional(service.id)) }
                            }
                            NavigationLink("管理翻译服务") { TranslationServicesSettingsView() }
                            TextField("翻译模型", text: $model)
                            LanguagePicker(title: "目标语言", selection: $target)
                            TextField("每批字幕数量", value: $batchSize, format: .number)
                            TextEditor(text: $prompt).frame(minHeight: 100).accessibilityLabel("系统提示词")
                            Text("字幕文本发送至所选服务，音频保持本地。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("SRT 输出") {
                    ForEach([SRTOutputKind.source, .translation, .bilingual], id: \.self) { output in
                        Toggle(output.label, isOn: Binding(get: { outputs.contains(output) }, set: {
                            if $0 { outputs.insert(output) } else { outputs.remove(output) }
                        })).disabled(output != .source && !enabled)
                    }
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            }
            .navigationTitle("调整翻译与输出")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(isSaving || store.isLoading || store.isSaving)
                }
            }
            .onChange(of: enabled) { _, enabled in if !enabled { outputs = [.source] } }
            .onChange(of: serviceID) { _, id in
                if let service = store.services.first(where: { $0.id == id }) {
                    model = service.modelID
                }
            }
            .confirmationDialog("更换目标语言？", isPresented: $replacement, titleVisibility: .visible) {
                Button("清除现有译文并保存", role: .destructive) { save(discardingTranslations: true) }
                Button("取消", role: .cancel) {}
            } message: { Text("现有译文将清除，原文、时间、转写成果与待校对标记保持。") }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func save(discardingTranslations: Bool = false) {
        isSaving = true
        defer { isSaving = false }
        do {
            var parameters = original.parameters
            if !enabled { parameters.translation = nil }
            else if apple {
                parameters.translation = try TranslationSettings(appleSourceLanguage: source, targetLanguage: target, batchSize: batchSize)
            } else {
                guard let service = store.services.first(where: { $0.id == serviceID }) else {
                    throw TaskValidationError.unconfiguredTranslationService
                }
                parameters.translation = try TranslationSettings(baseURL: service.baseURL, modelID: model,
                    targetLanguage: target, serviceID: service.id, batchSize: batchSize, systemPrompt: prompt)
            }
            parameters.srtOutputs = [.source, .translation, .bilingual].filter { outputs.contains($0) }
            var updated = original
            try updated.updateParameters(parameters, discardingTranslations: discardingTranslations)
            try onCommit(updated, original)
            dismiss()
        } catch TaskValidationError.translationReplacementRequired { replacement = true }
        catch { errorMessage = error.localizedDescription }
    }
}
