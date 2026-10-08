import SwiftUI
import VoxlineCore
import VoxlineTranslation

public struct CloudTranscriptionServicesSettingsView: View {
    @State private var store = CloudTranscriptionServiceStore.shared
    @State private var isAddingService = false
    @State private var editingService: CloudTranscriptionServiceConfig?
    @State private var errorMessage: String?
    @State private var deletingService: CloudTranscriptionServiceConfig?
    private var referencedService: CloudTranscriptionServiceConfig?

    public init(referencedSettings: TranscriptionSettings? = nil) {
        if let cloud = referencedSettings?.cloud {
            referencedService = .init(id: cloud.serviceID, name: String(localized: "云端转写", bundle: appLocalizationBundle), baseURL: cloud.baseURL, modelID: referencedSettings?.modelID ?? "whisper-1", protocolKind: cloud.protocolKind)
        }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let referencedService, !store.services.contains(where: { $0.id == referencedService.id }) {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.blue)
                        Text(String(localized: "当前任务引用的转写服务尚未在此设备配置", bundle: appLocalizationBundle))
                            .font(.subheadline)
                        Spacer()
                        Button(String(localized: "配置此服务", bundle: appLocalizationBundle)) { editingService = referencedService }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .padding(12)
                    .background(Color.blue.opacity(0.08), in: .rect(cornerRadius: 8))
                }

                if store.isLoading {
                    ProgressView(String(localized: "正在读取服务…", bundle: appLocalizationBundle))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                }

                if let error = store.errorMessage {
                    HStack {
                        Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        Spacer()
                        Button(String(localized: "重试", bundle: appLocalizationBundle)) { Task { await store.load() } }.disabled(store.isLoading || store.isSaving)
                    }
                }

                if store.services.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "尚未配置云端转写服务", bundle: appLocalizationBundle), systemImage: "waveform.badge.mic")
                    } description: {
                        Text(String(localized: "添加兼容接口以启用云端转写", bundle: appLocalizationBundle))
                    } actions: {
                        Button {
                            isAddingService = true
                        } label: {
                            Label(String(localized: "添加转写服务", bundle: appLocalizationBundle), systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isLoading || store.isSaving)
                    }
                    .padding(.vertical, 60)
                    .frame(maxWidth: .infinity)
                } else {
                    HStack {
                        Text(String(localized: "已配置服务", bundle: appLocalizationBundle))
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            isAddingService = true
                        } label: {
                            Label(String(localized: "添加服务", bundle: appLocalizationBundle), systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(store.isLoading || store.isSaving)
                    }

                    VStack(spacing: 12) {
                        ForEach(store.services) { service in
                            serviceCard(service: service)
                        }
                    }
                }
            }
            .padding(24)
        }
        #if os(iOS)
        .navigationTitle(String(localized: "云端转写服务", bundle: appLocalizationBundle))
        #endif
        .sheet(isPresented: $isAddingService) {
            CloudTranscriptionServiceEditorModal(service: nil, store: store)
        }
        .sheet(item: $editingService) { service in
            CloudTranscriptionServiceEditorModal(service: service, store: store)
        }
        .confirmationDialog(String(localized: "删除转写服务？", bundle: appLocalizationBundle), isPresented: Binding(
            get: { deletingService != nil }, set: { if !$0 { deletingService = nil } }), titleVisibility: .visible) {
            Button(String(localized: "删除服务与本地密钥", bundle: appLocalizationBundle), role: .destructive) {
                guard let service = deletingService else { return }
                Task {
                    do {
                        try await store.remove(id: service.id)
                        deletingService = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            Button(String(localized: "取消", bundle: appLocalizationBundle), role: .cancel) { deletingService = nil }
        } message: {
            Text(String(localized: "将从本设备删除该服务配置及钥匙串密钥。", bundle: appLocalizationBundle))
        }
        .alert(String(localized: "服务操作失败", bundle: appLocalizationBundle), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(String(localized: "好", bundle: appLocalizationBundle), role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder
    private func serviceCard(service: CloudTranscriptionServiceConfig) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.purple.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "waveform")
                    .font(.system(size: 20))
                    .foregroundStyle(.purple)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(service.name)
                        .font(.headline)
                    Text(service.protocolKind.label)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.12), in: .capsule)
                    Text(service.modelID)
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: .capsule)
                }

                Text(service.baseURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Image(systemName: store.credentialPresence[service.id] == true ? "key.fill" : "key.slash")
                        .font(.caption2)
                        .foregroundStyle(store.credentialPresence[service.id] == true ? .green : .secondary)
                    Text(store.credentialPresence[service.id] == true ? String(localized: "已存入钥匙串", bundle: appLocalizationBundle) : String(localized: "无密钥", bundle: appLocalizationBundle))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button(String(localized: "编辑", bundle: appLocalizationBundle)) { editingService = service }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button(String(localized: "删除", bundle: appLocalizationBundle), role: .destructive) { deletingService = service }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .liquidGlassSurface()
    }
}

private struct CloudTranscriptionServiceEditorModal: View {
    let original: CloudTranscriptionServiceConfig?
    let store: CloudTranscriptionServiceStore
    @Environment(\.dismiss) private var dismiss

    @State private var protocolKind: CloudTranscriptionProtocol
    @State private var name: String
    @State private var baseURLString: String
    @State private var modelID: String
    @State private var apiKey: String
    @State private var errorMessage: String?
    @State private var isLoadingKey: Bool
    @State private var isSaving = false
    @State private var keyReadFailed = false

    init(service: CloudTranscriptionServiceConfig?, store: CloudTranscriptionServiceStore) {
        self.original = service
        self.store = store
        let proto = service?.protocolKind ?? .audioTranscriptions
        _protocolKind = State(initialValue: proto)
        _name = State(initialValue: service?.name ?? "")
        _baseURLString = State(initialValue: service?.baseURL.absoluteString ?? Self.defaultURL(for: proto))
        _modelID = State(initialValue: service?.modelID ?? Self.defaultModel(for: proto))
        _apiKey = State(initialValue: "")
        _isLoadingKey = State(initialValue: service.map { s in store.services.contains(where: { $0.id == s.id }) } ?? false)
    }

    private static func defaultURL(for proto: CloudTranscriptionProtocol) -> String {
        switch proto {
        case .audioTranscriptions: "https://api.openai.com/v1"
        case .geminiAudioChat: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .qwenAudioChat: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        }
    }

    private static func defaultModel(for proto: CloudTranscriptionProtocol) -> String {
        switch proto {
        case .audioTranscriptions: "whisper-1"
        case .geminiAudioChat: "gemini-2.5-flash"
        case .qwenAudioChat: "qwen3-asr-flash"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(original == nil ? String(localized: "添加转写服务", bundle: appLocalizationBundle) : String(localized: "编辑转写服务", bundle: appLocalizationBundle))
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.regularMaterial)

            Divider()

            Form {
                Section(String(localized: "服务接入", bundle: appLocalizationBundle)) {
                    Picker(String(localized: "预设协议", bundle: appLocalizationBundle), selection: $protocolKind) {
                        ForEach(CloudTranscriptionProtocol.allCases, id: \.self) { proto in
                            Text(proto.label).tag(proto)
                        }
                    }
                    .onChange(of: protocolKind) { oldProto, newProto in
                        guard oldProto != newProto else { return }
                        switch newProto {
                        case .audioTranscriptions:
                            modelID = "whisper-1"
                            if baseURLString.isEmpty || baseURLString == Self.defaultURL(for: .geminiAudioChat) || baseURLString == Self.defaultURL(for: .qwenAudioChat) {
                                baseURLString = Self.defaultURL(for: .audioTranscriptions)
                            }
                        case .geminiAudioChat:
                            if modelID == "whisper-1" || modelID.isEmpty || modelID == Self.defaultModel(for: .qwenAudioChat) {
                                modelID = Self.defaultModel(for: .geminiAudioChat)
                            }
                            if baseURLString.isEmpty || baseURLString == Self.defaultURL(for: .audioTranscriptions) || baseURLString == Self.defaultURL(for: .qwenAudioChat) {
                                baseURLString = Self.defaultURL(for: .geminiAudioChat)
                            }
                        case .qwenAudioChat:
                            if modelID == "whisper-1" || modelID.isEmpty || modelID == Self.defaultModel(for: .geminiAudioChat) {
                                modelID = Self.defaultModel(for: .qwenAudioChat)
                            }
                            if baseURLString.isEmpty || baseURLString == Self.defaultURL(for: .audioTranscriptions) || baseURLString == Self.defaultURL(for: .geminiAudioChat) {
                                baseURLString = Self.defaultURL(for: .qwenAudioChat)
                            }
                        }
                    }

                    TextField(String(localized: "名称", bundle: appLocalizationBundle), text: $name, prompt: Text(placeholderName))
                    TextField(String(localized: "API 根地址", bundle: appLocalizationBundle), text: $baseURLString, prompt: Text(Self.defaultURL(for: protocolKind)))

                    if protocolKind == .audioTranscriptions {
                        HStack {
                            Text(String(localized: "转写模型", bundle: appLocalizationBundle))
                            Spacer()
                            Text("whisper-1")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        TextField(String(localized: "转写模型", bundle: appLocalizationBundle), text: $modelID, prompt: Text(placeholderModel))
                    }

                    if isLoadingKey {
                        ProgressView(String(localized: "正在从钥匙串安全读取密钥…", bundle: appLocalizationBundle))
                            .font(.caption)
                    } else {
                        PasswordVisibilityField(String(localized: "API 密钥（选填）", bundle: appLocalizationBundle), text: $apiKey)
                    }
                    if keyReadFailed {
                        Text(String(localized: "未能读取已存密钥，可重新输入更新。", bundle: appLocalizationBundle))
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button(String(localized: "取消", bundle: appLocalizationBundle)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button(String(localized: "保存", bundle: appLocalizationBundle)) { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || isLoadingKey || (keyReadFailed && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (protocolKind != .audioTranscriptions && modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial)
        }
        .frame(minWidth: 480, minHeight: 400)
        .task {
            if let original, isLoadingKey {
                do {
                    apiKey = try await store.editingAPIKey(serviceID: original.id)
                    isLoadingKey = false
                } catch {
                    keyReadFailed = true
                    isLoadingKey = false
                }
            }
        }
    }

    private var placeholderName: String {
        switch protocolKind {
        case .audioTranscriptions: String(localized: "例如 OpenAI / 自建 Whisper", bundle: appLocalizationBundle)
        case .geminiAudioChat: String(localized: "例如 Google Gemini", bundle: appLocalizationBundle)
        case .qwenAudioChat: String(localized: "例如 阿里百炼 / 通义千问", bundle: appLocalizationBundle)
        }
    }

    private var placeholderModel: String {
        switch protocolKind {
        case .audioTranscriptions: "whisper-1"
        case .geminiAudioChat: String(localized: "例如 gemini-2.5-flash", bundle: appLocalizationBundle)
        case .qwenAudioChat: String(localized: "例如 qwen3-asr-flash", bundle: appLocalizationBundle)
        }
    }

    private func save() {
        guard let url = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else {
            errorMessage = String(localized: "请输入有效的 HTTP 或 HTTPS API 根地址。", bundle: appLocalizationBundle)
            return
        }
        let finalModel = protocolKind == .audioTranscriptions ? "whisper-1" : modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalModel.isEmpty else {
            errorMessage = String(localized: "请输入转写模型 ID。", bundle: appLocalizationBundle)
            return
        }
        let config = CloudTranscriptionServiceConfig(
            id: original?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: url,
            modelID: finalModel,
            protocolKind: protocolKind
        )
        do {
            _ = try config.settings()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await store.addOrUpdate(config, apiKey: apiKey)
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
