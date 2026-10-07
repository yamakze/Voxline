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
                        Text("任务正在处理中，不可更换转写服务。请先等待当前操作结束或取消处理。")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }

                Section("当前转写配置") {
                    if let currentCloud {
                        let currentServiceName = store.services.first(where: { $0.id == currentCloud.serviceID })?.name ?? "未在本机配置的服务"
                        LabeledContent("当前服务", value: currentServiceName)
                        LabeledContent("预设协议", value: currentCloud.protocolKind.label)
                        LabeledContent("转写模型", value: currentTranscription.modelID)
                        LabeledContent("API 地址", value: currentCloud.baseURL.absoluteString)
                    } else {
                        LabeledContent("当前转写", value: "本地 WhisperKit")
                    }
                    LabeledContent("语言识别", value: currentTranscription.languageMode == .specified ? (currentTranscription.languageCode ?? "未指定") : "自动识别")
                }

                Section("目标转写服务") {
                    if store.services.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("本机尚未配置任何云端转写服务。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button("配置转写服务…") {
                                showManageServices = true
                            }
                            .buttonStyle(.bordered)
                        }
                    } else {
                        Picker("选择新服务", selection: $selectedServiceID) {
                            Text("请选择服务").tag(nil as UUID?)
                            ForEach(store.services) { service in
                                Text(service.name).tag(Optional(service.id))
                            }
                        }

                        if let service = selectedService {
                            LabeledContent("协议", value: service.protocolKind.label)
                            LabeledContent("模型", value: service.modelID)
                            LabeledContent("API 地址", value: service.baseURL.absoluteString)

                            if isIncompatibleProtocolSwitch {
                                Text("⚠️ 当前任务已有转写成果。Audio Transcriptions（整段转写）与音频聊天预设（语音分块）之间的切分机制不同，已有检查点的任务无法切换，请新建任务。")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            } else if service.id == currentCloud?.serviceID {
                                Text("所选服务与当前已绑定的服务相同。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("更换后将保留已有转写成果与人工校对，后续未转写的音频将使用新配置。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button("管理转写服务…") {
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
            .navigationTitle("更换转写服务")
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 380)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认更换") {
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
