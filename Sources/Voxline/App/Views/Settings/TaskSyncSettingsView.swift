import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore
import VoxlineWorkflow

public struct TaskSyncSettingsView: View {
    @State private var settings = TaskSyncSettings.shared
    @State private var isSelectingFolder = false
    @State private var pendingFolderURL: URL?
    @State private var pendingSummary: TaskSyncSettings.MigrationSummary?
    @State private var showMigrationSheet = false
    @State private var showDisableConfirmation = false
    @State private var syncOriginalsInMigration = false
    @State private var isProcessing = false
    @State private var localError: String?

    public init() {}

    public var body: some View {
        Form {
            Section("iCloud 文件夹同步") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(settings.isEnabled ? "同步已启用" : "未启用同步")
                            .font(.headline)
                        if let folder = settings.folderURL {
                            Text(folder.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        } else {
                            Text("选择 iCloud Drive 文件夹以跨设备同步任务与字幕。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if settings.isChanging || isProcessing {
                        ProgressView().controlSize(.small)
                    } else if settings.isEnabled {
                        Button("关闭同步", role: .destructive) {
                            showDisableConfirmation = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Button("选择文件夹…") {
                            isSelectingFolder = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                if settings.isEnabled {
                    Button("更换同步文件夹…") {
                        isSelectingFolder = true
                    }
                    .font(.caption)
                    .disabled(settings.isChanging || settings.isCopyingOriginalMedia || isProcessing)
                }
            }

            if settings.isEnabled {
                Section("原媒体同步") {
                    Toggle("同步源音视频文件", isOn: Binding(
                        get: { settings.syncOriginalMedia },
                        set: { newValue in
                            Task {
                                isProcessing = true
                                defer { isProcessing = false }
                                do {
                                    try await settings.setOriginalMediaSync(newValue)
                                } catch {
                                    localError = error.localizedDescription
                                }
                            }
                        }
                    ))
                    .disabled(settings.isChanging || settings.isCopyingOriginalMedia || isProcessing)

                    if settings.isCopyingOriginalMedia {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在复制并上传原音视频到云端…")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    } else {
                        Text("关闭时仅在本机保留原视频，云端仅同步字幕与任务进度。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if settings.syncOriginalMedia {
                        Button("重试原媒体上传") {
                            Task {
                                isProcessing = true
                                defer { isProcessing = false }
                                do {
                                    try await settings.retryOriginalMediaUpload()
                                } catch {
                                    localError = error.localizedDescription
                                }
                            }
                        }
                        .font(.caption)
                        .disabled(settings.isChanging || settings.isCopyingOriginalMedia || isProcessing)
                    }
                }

                Section("同步状态") {
                    HStack {
                        Text("当前监控文件")
                        Spacer()
                        Text("\(settings.fileStates.count) 个")
                            .foregroundStyle(.secondary)
                    }

                    Button("刷新状态") {
                        settings.refresh()
                    }
                    .font(.caption)
                    .disabled(settings.isChanging || isProcessing)
                }
            }

            if let error = settings.errorMessage ?? localError {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    Button("重试 / 刷新") {
                        localError = nil
                        settings.refresh()
                    }
                    .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .navigationTitle("iCloud 文件夹同步")
        #endif
        .fileImporter(
            isPresented: $isSelectingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .failure(let error):
                localError = error.localizedDescription
            case .success(let urls):
                guard let folder = urls.first else { return }
                prepareMigration(for: folder)
            }
        }
        .sheet(isPresented: $showMigrationSheet) {
            if let folder = pendingFolderURL, let summary = pendingSummary {
                migrationConfirmationSheet(folder: folder, summary: summary)
            }
        }
        .confirmationDialog(
            "关闭 iCloud 文件夹同步？",
            isPresented: $showDisableConfirmation,
            titleVisibility: .visible
        ) {
            Button("保存本地成果并关闭", role: .destructive) {
                disableSync()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("关闭后任务将仅保存在本机，云端现有文件不会被删除。")
        }
        .alert("操作失败", isPresented: Binding(
            get: { localError != nil },
            set: { if !$0 { localError = nil } }
        )) {
            Button("好", role: .cancel) { localError = nil }
        } message: {
            Text(localError ?? "")
        }
    }

    private func prepareMigration(for folder: URL) {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }

        do {
            let summary = try settings.migrationSummary()
            pendingFolderURL = folder
            pendingSummary = summary
            syncOriginalsInMigration = false
            showMigrationSheet = true
        } catch {
            localError = "迁移检查失败：\(error.localizedDescription)"
        }
    }

    private func migrationConfirmationSheet(folder: URL, summary: TaskSyncSettings.MigrationSummary) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("启用 iCloud 文件夹同步")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.regularMaterial)

            Divider()

            Form {
                Section("目标同步文件夹") {
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.blue)
                        Text(folder.lastPathComponent)
                            .font(.headline)
                    }
                    Text(folder.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("本地成果迁移") {
                    HStack {
                        Text("任务文档数")
                        Spacer()
                        Text("\(summary.taskCount) 个")
                            .bold()
                    }
                    HStack {
                        Text("关联原媒体文件")
                        Spacer()
                        Text("\(summary.mediaCount) 个 (\(ByteCountFormatter.string(fromByteCount: summary.mediaBytes, countStyle: .file)))")
                            .bold()
                    }
                }

                Section("原媒体同步选项") {
                    Toggle("同时复制并同步原音视频文件", isOn: $syncOriginalsInMigration)
                    Text("同时将源音视频上传至云端供其他设备直接下载（需要较多存储与网络带宽）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("取消") {
                    showMigrationSheet = false
                    pendingFolderURL = nil
                    pendingSummary = nil
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isProcessing)

                Button("迁移并启用") {
                    commitEnable(folder: folder, originals: syncOriginalsInMigration)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isProcessing)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial)
        }
        .frame(minWidth: 460, minHeight: 380)
    }

    private func commitEnable(folder: URL, originals: Bool) {
        isProcessing = true
        localError = nil
        Task {
            do {
                try await settings.enable(folder: folder, originals: originals)
                isProcessing = false
                showMigrationSheet = false
                pendingFolderURL = nil
                pendingSummary = nil
            } catch {
                isProcessing = false
                localError = error.localizedDescription
            }
        }
    }

    private func disableSync() {
        isProcessing = true
        localError = nil
        do {
            try settings.disable()
            isProcessing = false
        } catch {
            isProcessing = false
            localError = error.localizedDescription
        }
    }
}
