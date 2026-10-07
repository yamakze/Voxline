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
            referencedService = .init(id: cloud.serviceID, name: "云端转写", baseURL: cloud.baseURL, modelID: referencedSettings?.modelID ?? "whisper-1")
        }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let referencedService, !store.services.contains(where: { $0.id == referencedService.id }) {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.blue)
                        Text("当前任务引用的转写服务尚未在此设备配置")
                            .font(.subheadline)
                        Spacer()
                        Button("配置此服务") { editingService = referencedService }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .padding(12)
                    .background(Color.blue.opacity(0.08), in: .rect(cornerRadius: 8))
                }

                if store.isLoading {
                    ProgressView("正在读取服务…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                }

                if let error = store.errorMessage {
                    HStack {
                        Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        Spacer()
                        Button("重试") { Task { await store.load() } }.disabled(store.isLoading || store.isSaving)
                    }
                }

                if store.services.isEmpty {
                    ContentUnavailableView(
                        "尚未配置云端转写服务",
                        systemImage: "waveform.badge.mic",
                        description: Text("配置 OpenAI Audio Transcriptions 兼容接口以启用云端转写。")
                    )
                    .padding(.vertical, 60)
                    .frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 12) {
                        ForEach(store.services) { service in
                            serviceCard(service: service)
                        }
                    }
                }
            }
            .padding(24)
        }
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .navigation) {
                Text("云端转写服务")
                    .font(.headline)
            }
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 1, height: 1)
            }
            #endif
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isAddingService = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("添加转写服务…")
                .disabled(store.isLoading || store.isSaving)
            }
        }
        .navigationTitle("云端转写服务")
        .sheet(isPresented: $isAddingService) {
            CloudTranscriptionServiceEditorModal(service: nil, store: store)
        }
        .sheet(item: $editingService) { service in
            CloudTranscriptionServiceEditorModal(service: service, store: store)
        }
        .confirmationDialog("删除转写服务？", isPresented: Binding(
            get: { deletingService != nil }, set: { if !$0 { deletingService = nil } }), titleVisibility: .visible) {
            Button("删除服务与本地密钥", role: .destructive) {
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
            Button("取消", role: .cancel) { deletingService = nil }
        } message: {
            Text("将从本设备删除该服务配置及钥匙串密钥，已完成的任务不受影响。")
        }
        .alert("服务操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
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
                    Text("whisper-1")
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
                    Text(store.credentialPresence[service.id] == true ? "已存入钥匙串" : "无密钥")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button("编辑") { editingService = service }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("删除", role: .destructive) { deletingService = service }
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

    @State private var name: String
    @State private var baseURLString: String
    @State private var apiKey: String
    @State private var errorMessage: String?
    @State private var isLoadingKey: Bool
    @State private var isSaving = false
    @State private var keyReadFailed = false

    init(service: CloudTranscriptionServiceConfig?, store: CloudTranscriptionServiceStore) {
        self.original = service
        self.store = store
        _name = State(initialValue: service?.name ?? "")
        _baseURLString = State(initialValue: service?.baseURL.absoluteString ?? "https://api.openai.com/v1")
        _apiKey = State(initialValue: "")
        _isLoadingKey = State(initialValue: service.map { s in store.services.contains(where: { $0.id == s.id }) } ?? false)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(original == nil ? "添加转写服务" : "编辑转写服务")
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.regularMaterial)

            Divider()

            Form {
                Section("服务接入") {
                    TextField("名称", text: $name, prompt: Text("例如 OpenAI / 自建 Whisper"))
                    TextField("API 根地址", text: $baseURLString, prompt: Text("https://api.openai.com/v1"))
                    HStack {
                        Text("转写模型")
                        Spacer()
                        Text("whisper-1")
                            .foregroundStyle(.secondary)
                    }
                    if isLoadingKey {
                        ProgressView("正在从钥匙串安全读取密钥…")
                            .font(.caption)
                    } else {
                        PasswordVisibilityField("API 密钥（选填）", text: $apiKey)
                    }
                    if keyReadFailed {
                        Text("读取钥匙串密钥失败，如需更新请重新输入。")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }

                Section {
                    Text("当前协议固定 whisper-1、verbose_json 与 segment 时间戳，单次分块上限 120 秒 / 25 MB。密钥仅保存在本机钥匙串。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                Button("取消") { dismiss() }
                    .disabled(isSaving)
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || isLoadingKey || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial)
        }
        .frame(minWidth: 480, minHeight: 380)
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

    private func save() {
        guard let url = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else {
            errorMessage = "请输入有效的 HTTP 或 HTTPS API 根地址。"
            return
        }
        let config = CloudTranscriptionServiceConfig(
            id: original?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: url,
            modelID: "whisper-1"
        )
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
