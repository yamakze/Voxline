import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore
import VoxlineWorkflow
#if os(macOS)
import AppKit
#endif

public struct TaskSyncSettingsView: View {
    @State private var settings = TaskSyncCoordinator.shared
    @State private var isSelectingFolder = false
    @State private var pendingFolderURL: URL?
    @State private var pendingSummary: TaskSyncCoordinator.MigrationSummary?
    @State private var showMigrationSheet = false
    @State private var showDisableConfirmation = false
    @State private var syncOriginalsInMigration = false
    @State private var isProcessing = false
    @State private var localError: String?

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !settings.isEnabled {
                    // 未启用时展示与翻译/转写一致的标准 ContentUnavailableView
                    ContentUnavailableView {
                        Label(String(localized: "未启用 iCloud 同步", bundle: appLocalizationBundle), systemImage: "icloud.slash")
                    } description: {
                        Text(String(localized: "通过 iCloud Drive 目录跨设备同步您的任务项目与字幕成果。", bundle: appLocalizationBundle))
                    } actions: {
                        Button {
                            isSelectingFolder = true
                        } label: {
                            Label(String(localized: "选择同步文件夹…", bundle: appLocalizationBundle), systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(settings.isChanging || isProcessing)
                    }
                    .padding(.vertical, 60)
                    .frame(maxWidth: .infinity)
                } else {
                    // 1. 同步状态与目录
                    Text(String(localized: "同步状态与目录", bundle: appLocalizationBundle))
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    folderLocationCard

                    // 2. 媒体同步策略
                    Text(String(localized: "媒体同步策略", bundle: appLocalizationBundle))
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    mediaSyncPolicyCard

                    // 3. 实时同步统计
                    Text(String(localized: "实时同步状态与统计", bundle: appLocalizationBundle))
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    liveMonitorCard

                    // 4. 底部管理操作
                    HStack {
                        Spacer()
                        Button(role: .destructive) {
                            showDisableConfirmation = true
                        } label: {
                            Text(String(localized: "关闭 iCloud 同步", bundle: appLocalizationBundle))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(settings.isChanging || isProcessing)
                    }
                    .padding(.top, 6)
                }

                if let error = settings.errorMessage ?? localError {
                    errorBanner(error)
                }
            }
            .padding(24)
        }
        #if os(iOS)
        .navigationTitle(String(localized: "iCloud 同步", bundle: appLocalizationBundle))
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
            String(localized: "关闭 iCloud 文件夹同步？", bundle: appLocalizationBundle),
            isPresented: $showDisableConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "保存本地成果并关闭", bundle: appLocalizationBundle), role: .destructive) {
                disableSync()
            }
            Button(String(localized: "取消", bundle: appLocalizationBundle), role: .cancel) {}
        } message: {
            Text(String(localized: "关闭后任务将仅保存在本机，云端现有文件不会被删除。", bundle: appLocalizationBundle))
        }
        .alert(String(localized: "操作失败", bundle: appLocalizationBundle), isPresented: Binding(
            get: { localError != nil },
            set: { if !$0 { localError = nil } }
        )) {
            Button(String(localized: "好", bundle: appLocalizationBundle), role: .cancel) { localError = nil }
        } message: {
            Text(localError ?? "")
        }
    }

    // MARK: - Folder Location Card
    private var folderLocationCard: some View {
        Group {
            if let folder = settings.folderURL {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.voxlineAccent)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(folder.lastPathComponent)
                                .font(.system(size: 15, weight: .semibold))

                            HStack(spacing: 4) {
                                Circle().fill(Color.green).frame(width: 7, height: 7)
                                Text(String(localized: "已启用", bundle: appLocalizationBundle))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.green)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.12), in: .capsule)
                        }

                        Text(folder.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        #if os(macOS)
                        Button(String(localized: "在访达中显示", bundle: appLocalizationBundle)) {
                            NSWorkspace.shared.activateFileViewerSelecting([folder])
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        #endif

                        Button(String(localized: "更换文件夹…", bundle: appLocalizationBundle)) {
                            isSelectingFolder = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(settings.isChanging || settings.isCopyingOriginalMedia || isProcessing)
                    }
                }
                .padding(14)
                .liquidGlassSurface()
            }
        }
    }

    // MARK: - Media Sync Policy Card
    private var mediaSyncPolicyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "同步原音视频媒体文件", bundle: appLocalizationBundle))
                        .font(.subheadline.weight(.medium))

                    Text(settings.syncOriginalMedia
                        ? String(localized: "完整镜像模式：音视频文件将同步至云端，供其他设备直接播放，消耗较多云盘空间。", bundle: appLocalizationBundle)
                        : String(localized: "节省空间模式：仅同步任务配置与字幕文字，原始音视频保留在本地。", bundle: appLocalizationBundle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: Binding(
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
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(settings.isChanging || settings.isCopyingOriginalMedia || isProcessing)
            }

            if settings.isCopyingOriginalMedia {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "正在同步原媒体文件…", bundle: appLocalizationBundle))
                        .font(.caption)
                        .foregroundStyle(Color.voxlineAccent)
                }
                .padding(.top, 2)
            } else if settings.syncOriginalMedia {
                HStack {
                    Spacer()
                    Button(String(localized: "重试原媒体上传", bundle: appLocalizationBundle), systemImage: "arrow.clockwise") {
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
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(settings.isChanging || settings.isCopyingOriginalMedia || isProcessing)
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .liquidGlassSurface()
    }

    // MARK: - Live Sync Monitor Card
    private var liveMonitorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            let taskCount = settings.fileStates.keys.filter { $0.pathExtension == "voxline" }.count
            let mediaCount = settings.fileStates.keys.filter { $0.pathExtension != "voxline" }.count
            let conflictCount = settings.fileStates.values.filter { $0 == .conflict }.count
            let uploadingCount = settings.fileStates.values.filter { $0 == .uploading || $0 == .waitingForUpload }.count
            let downloadingCount = settings.fileStates.values.filter { $0 == .downloading || $0 == .notDownloaded }.count

            HStack(spacing: 20) {
                HStack(spacing: 7) {
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(.blue)
                        .font(.callout)
                    Text(String(localized: "任务文档", bundle: appLocalizationBundle))
                        .foregroundStyle(.secondary)
                    Text("\(taskCount)")
                        .font(.callout.weight(.semibold))
                }

                Divider().frame(height: 14)

                HStack(spacing: 7) {
                    Image(systemName: "film.fill")
                        .foregroundStyle(.purple)
                        .font(.callout)
                    Text(String(localized: "原媒体文件", bundle: appLocalizationBundle))
                        .foregroundStyle(.secondary)
                    Text("\(mediaCount)")
                        .font(.callout.weight(.semibold))
                }

                Divider().frame(height: 14)

                HStack(spacing: 7) {
                    Image(systemName: "arrow.up.arrow.down")
                        .foregroundStyle(uploadingCount + downloadingCount > 0 ? Color.voxlineAccent : .secondary)
                        .font(.callout)
                    Text(String(localized: "传输中", bundle: appLocalizationBundle))
                        .foregroundStyle(.secondary)
                    Text("\(uploadingCount + downloadingCount)")
                        .font(.callout.weight(.semibold))
                }

                Spacer()
            }
            .font(.callout)

            if conflictCount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(String(localized: "检测到 \(conflictCount) 个版本冲突文档，可在任务列表中点击“解决冲突”进行合并。", bundle: appLocalizationBundle))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 8))
            }
        }
        .padding(14)
        .liquidGlassSurface()
    }

    // MARK: - Error Banner
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "同步异常", bundle: appLocalizationBundle))
                    .font(.subheadline.bold())
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button(String(localized: "重试 / 刷新", bundle: appLocalizationBundle)) {
                localError = nil
                do { try settings.retryPublication() }
                catch { localError = error.localizedDescription }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(14)
        .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 12))
    }

    // MARK: - Migration Sheet & Helpers
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
            localError = String(localized: "迁移检查失败：\(error.localizedDescription)", bundle: appLocalizationBundle)
        }
    }

    private func migrationConfirmationSheet(folder: URL, summary: TaskSyncCoordinator.MigrationSummary) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "启用 iCloud 文件夹同步", bundle: appLocalizationBundle))
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.regularMaterial)

            Divider()

            Form {
                Section(String(localized: "目标同步文件夹", bundle: appLocalizationBundle)) {
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

                Section(String(localized: "本地成果迁移", bundle: appLocalizationBundle)) {
                    HStack {
                        Text(String(localized: "任务文档数", bundle: appLocalizationBundle))
                        Spacer()
                        Text(String(localized: "\(summary.taskCount) 个", bundle: appLocalizationBundle))
                            .bold()
                    }
                    HStack {
                        Text(String(localized: "关联原媒体文件", bundle: appLocalizationBundle))
                        Spacer()
                        Text(String(localized: "\(summary.mediaCount) 个 (\(ByteCountFormatter.string(fromByteCount: summary.mediaBytes, countStyle: .file)))", bundle: appLocalizationBundle))
                            .bold()
                    }
                }

                Section(String(localized: "原媒体同步选项", bundle: appLocalizationBundle)) {
                    Toggle(String(localized: "同时复制并同步原音视频文件", bundle: appLocalizationBundle), isOn: $syncOriginalsInMigration)
                    Text(String(localized: "同时将源音视频上传至云端供其他设备直接下载（需要较多存储与网络带宽）。", bundle: appLocalizationBundle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button(String(localized: "取消", bundle: appLocalizationBundle)) {
                    showMigrationSheet = false
                    pendingFolderURL = nil
                    pendingSummary = nil
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isProcessing)

                Button(String(localized: "迁移并启用", bundle: appLocalizationBundle)) {
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
