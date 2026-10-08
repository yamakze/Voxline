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
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "转写", bundle: appLocalizationBundle)) {
                    let transcription = original.parameters.transcription
                    if transcription.provider == .openAICompatible {
                        LabeledContent(String(localized: "转写路线", bundle: appLocalizationBundle), value: String(localized: "云端 OpenAI 兼容", bundle: appLocalizationBundle))
                        LabeledContent(String(localized: "转写模型", bundle: appLocalizationBundle), value: transcription.modelID)
                        if let baseURL = transcription.cloud?.baseURL {
                            LabeledContent(String(localized: "服务地址", bundle: appLocalizationBundle), value: baseURL.absoluteString)
                        }
                    } else {
                        LabeledContent(String(localized: "转写路线", bundle: appLocalizationBundle), value: String(localized: "本地 WhisperKit", bundle: appLocalizationBundle))
                        LabeledContent(String(localized: "转写模型", bundle: appLocalizationBundle), value: transcription.modelID)
                    }
                    LabeledContent(String(localized: "语言识别", bundle: appLocalizationBundle), value: transcription.languageMode == .specified ? (transcription.languageCode ?? String(localized: "未指定", bundle: appLocalizationBundle)) : String(localized: "自动识别", bundle: appLocalizationBundle))
                }
                Section(String(localized: "字幕翻译", bundle: appLocalizationBundle)) {
                    Toggle(String(localized: "启用翻译", bundle: appLocalizationBundle), isOn: $enabled)
                    if enabled {
                        Picker(String(localized: "引擎", bundle: appLocalizationBundle), selection: $apple) {
                            Text(String(localized: "OpenAI 兼容接口", bundle: appLocalizationBundle)).tag(false)
                            Text(String(localized: "Apple 本机翻译", bundle: appLocalizationBundle)).tag(true)
                        }
                        if apple {
                            AppleTranslationLanguageSettings(source: $source, target: $target, batchSize: $batchSize)
                        } else {
                            Picker(String(localized: "本机服务", bundle: appLocalizationBundle), selection: $serviceID) {
                                Text(String(localized: "请选择服务", bundle: appLocalizationBundle)).tag(nil as UUID?)
                                if let serviceID, !store.services.contains(where: { $0.id == serviceID }) {
                                    Text(String(localized: "原服务未在此设备配置", bundle: appLocalizationBundle)).tag(Optional(serviceID))
                                }
                                ForEach(store.services) { service in Text(service.name).tag(Optional(service.id)) }
                            }
                            NavigationLink(String(localized: "管理翻译服务", bundle: appLocalizationBundle)) {
                                TranslationServicesSettingsView(referencedSettings: original.parameters.translation)
                            }
                            TextField(String(localized: "翻译模型", bundle: appLocalizationBundle), text: $model)
                            LanguagePicker(title: String(localized: "目标语言", bundle: appLocalizationBundle), selection: $target)
                            TextField(String(localized: "每批字幕数量", bundle: appLocalizationBundle), value: $batchSize, format: .number)
                            TextEditor(text: $prompt).frame(minHeight: 100).accessibilityLabel(String(localized: "系统提示词", bundle: appLocalizationBundle))
                        }
                    }
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            }
            .navigationTitle(String(localized: "调整翻译参数", bundle: appLocalizationBundle))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "取消", bundle: appLocalizationBundle)) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "保存", bundle: appLocalizationBundle)) { save() }.disabled(isSaving || store.isLoading || store.isSaving)
                }
            }
            .onChange(of: serviceID) { _, id in
                if let service = store.services.first(where: { $0.id == id }) {
                    model = service.modelID
                }
            }
            .confirmationDialog(String(localized: "更换目标语言？", bundle: appLocalizationBundle), isPresented: $replacement, titleVisibility: .visible) {
                Button(String(localized: "清除现有译文并保存", bundle: appLocalizationBundle), role: .destructive) { save(discardingTranslations: true) }
                Button(String(localized: "取消", bundle: appLocalizationBundle), role: .cancel) {}
            } message: { Text(String(localized: "现有译文将清除，原文、时间、转写成果与待校对标记保持。", bundle: appLocalizationBundle)) }
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
            parameters.srtOutputs = enabled ? [.bilingual, .source, .translation] : [.source]
            var updated = original
            try updated.updateParameters(parameters, discardingTranslations: discardingTranslations)
            try onCommit(updated, original)
            dismiss()
        } catch TaskValidationError.translationReplacementRequired { replacement = true }
        catch { errorMessage = error.localizedDescription }
    }
}
