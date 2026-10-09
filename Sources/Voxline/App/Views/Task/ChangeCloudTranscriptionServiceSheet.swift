import SwiftUI
import VoxlineCore
import VoxlineTranslation

public struct ChangeCloudTranscriptionServiceSheet: View {
    let task: ProcessingTask
    let onCommit: (ProcessingTask) throws -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var store = CloudTranscriptionServiceStore.shared
    @State private var selectedServiceID: UUID?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showManageServices = false

    public init(task: ProcessingTask, onCommit: @escaping (ProcessingTask) throws -> Void) {
        self.task = task
        self.onCommit = onCommit
    }

    private var currentTranscription: TranscriptionSettings {
        task.parameters.transcription
    }

    private var currentCloud: CloudTranscriptionConfiguration? {
        currentTranscription.cloud
    }

    private var isTaskRunning: Bool {
        task.items.contains(where: { if case .running = $0.status { true } else { false } })
    }

    private var hasCheckpoints: Bool {
        task.items.contains { $0.checkpoint != nil }
    }

    private var selectedService: CloudTranscriptionServiceConfig? {
        selectedServiceID.flatMap { id in store.services.first(where: { $0.id == id }) }
    }

    private var isIncompatibleProtocolSwitch: Bool {
        guard let currentCloud, let selectedService else { return false }
        return hasCheckpoints && (currentCloud.protocolKind.usesSpeechChunks != selectedService.protocolKind.usesSpeechChunks)
    }

    public var body: some View {
        NavigationStack {
            Form {
                if isTaskRunning {
                    Section {
                        Text(String(localized: "任务正在处理中，不可更换转写服务。请先等待当前操作结束或取消处理。", bundle: appLocalizationBundle))
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }

                Section(String(localized: "当前转写配置", bundle: appLocalizationBundle)) {
                    if let currentCloud {
                        let currentServiceName = store.services.first(where: { $0.id == currentCloud.serviceID })?.name ?? String(localized: "未在本机配置的服务", bundle: appLocalizationBundle)
                        LabeledContent(String(localized: "当前服务", bundle: appLocalizationBundle), value: currentServiceName)
                        LabeledContent(String(localized: "转写模型", bundle: appLocalizationBundle), value: currentTranscription.modelID)
                        LabeledContent(String(localized: "API 地址", bundle: appLocalizationBundle), value: currentCloud.baseURL.absoluteString)
                    } else {
                        LabeledContent(String(localized: "当前转写", bundle: appLocalizationBundle), value: String(localized: "本地 WhisperKit", bundle: appLocalizationBundle))
                    }
                    LabeledContent(String(localized: "语言识别", bundle: appLocalizationBundle), value: currentTranscription.languageMode == .specified ? (currentTranscription.languageCode ?? String(localized: "未指定", bundle: appLocalizationBundle)) : String(localized: "自动识别", bundle: appLocalizationBundle))
                }

                Section(String(localized: "目标转写服务", bundle: appLocalizationBundle)) {
                    if store.services.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(localized: "本机尚未配置任何云端转写服务。", bundle: appLocalizationBundle))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button(String(localized: "配置转写服务…", bundle: appLocalizationBundle)) {
                                showManageServices = true
                            }
                            .buttonStyle(.bordered)
                        }
                    } else {
                        Picker(String(localized: "选择新服务", bundle: appLocalizationBundle), selection: $selectedServiceID) {
                            Text(String(localized: "请选择服务", bundle: appLocalizationBundle)).tag(nil as UUID?)
                            ForEach(store.services) { service in
                                Text(service.name).tag(Optional(service.id))
                            }
                        }

                        if let service = selectedService {
                            LabeledContent(String(localized: "模型", bundle: appLocalizationBundle), value: service.modelID)
                            LabeledContent(String(localized: "API 地址", bundle: appLocalizationBundle), value: service.baseURL.absoluteString)

                            if isIncompatibleProtocolSwitch {
                                Text(String(localized: "⚠️ 当前任务已有转写成果，因转写机制不兼容，无法在不同类型的服务间直接切换。如需使用新服务，请新建任务。", bundle: appLocalizationBundle))
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            } else if service.id == currentCloud?.serviceID {
                                Text(String(localized: "所选服务与当前已绑定的服务相同。", bundle: appLocalizationBundle))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(String(localized: "更换后将保留已有转写成果与人工校对，后续未转写的音频将使用新配置。", bundle: appLocalizationBundle))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button(String(localized: "管理转写服务…", bundle: appLocalizationBundle)) {
                            showManageServices = true
                        }
                        .font(.caption)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "更换转写服务", bundle: appLocalizationBundle))
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 380)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消", bundle: appLocalizationBundle)) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "确认更换", bundle: appLocalizationBundle)) {
                        applyChange()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || isTaskRunning || selectedServiceID == nil || selectedServiceID == currentCloud?.serviceID || isIncompatibleProtocolSwitch)
                }
            }
            .sheet(isPresented: $showManageServices) {
                CloudTranscriptionServicesSettingsView(referencedSettings: currentTranscription)
            }
        }
    }

    private func applyChange() {
        guard let service = selectedService else { return }
        isSaving = true
        errorMessage = nil
        do {
            var updated = task
            let languageCode = currentTranscription.languageMode == .specified ? currentTranscription.languageCode : nil
            let newSettings = try service.settings(languageCode: languageCode)
            try updated.bindCloudTranscription(newSettings)
            try onCommit(updated)
            isSaving = false
            dismiss()
        } catch {
            isSaving = false
            errorMessage = error.localizedDescription
        }
    }
}
