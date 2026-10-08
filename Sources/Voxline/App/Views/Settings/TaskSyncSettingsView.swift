import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore
import VoxlineWorkflow
#if os(macOS)
import AppKit
#endif

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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 1. Hero Status Card
                heroStatusCard

                if settings.isEnabled {
                    // 2. Folder Location & Management Card
                    folderLocationCard

                    // 3. Media Sync Policy Card
                    mediaSyncPolicyCard

                    // 4. Live Sync Monitor & Health Stats Card
                    liveMonitorCard
                } else {
                    // Unconfigured Onboarding / Benefits Card
                    onboardingCard
                }

                if let error = settings.errorMessage ?? localError {
                    errorBanner(error)
                }
            }
            .padding(24)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        #if os(iOS)
        .navigationTitle(String(localized: "iCloud 文件夹同步", bundle: appLocalizationBundle))
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

    // MARK: - 1. Hero Status Card
    private var heroStatusCard: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(settings.isEnabled
                        ? LinearGradient(colors: [Color.blue.opacity(0.85), Color.cyan.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        : LinearGradient(colors: [Color.secondary.opacity(0.3), Color.secondary.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 48, height: 48)
                Image(systemName: settings.isEnabled ? "icloud.fill" : "icloud.slash.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(String(localized: "iCloud 文件夹同步", bundle: appLocalizationBundle))
                        .font(.title3.bold())
                    if settings.isChanging || isProcessing {
                        ProgressView().controlSize(.mini)
                        Text(String(localized: "正在处理…", bundle: appLocalizationBundle))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if settings.isEnabled {
                        HStack(spacing: 4) {
                            Circle().fill(Color.green).frame(width: 7, height: 7)
                            Text(String(localized: "同步运行中", bundle: appLocalizationBundle))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.12), in: .capsule)
                    } else {
                        HStack(spacing: 4) {
                            Circle().fill(Color.secondary).frame(width: 7, height: 7)
                            Text(String(localized: "未启用", bundle: appLocalizationBundle))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: .capsule)
                    }
                }

                Text(settings.isEnabled
                    ? String(localized: "已关联 iCloud Drive 专用目录，实时同步任务文档与字幕校对成果。", bundle: appLocalizationBundle)
                    : String(localized: "通过 iCloud Drive 目录跨设备同步您的任务项目与字幕成果。", bundle: appLocalizationBundle))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if settings.isEnabled {
                Button(role: .destructive) {
                    showDisableConfirmation = true
                } label: {
                    Text(String(localized: "关闭同步", bundle: appLocalizationBundle))
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(settings.isChanging || isProcessing)
            } else {
                Button {
                    isSelectingFolder = true
                } label: {
                    Label(String(localized: "选择文件夹…", bundle: appLocalizationBundle), systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(settings.isChanging || isProcessing)
            }
        }
        .padding(18)
        .liquidGlassSurface(cornerRadius: 14)
    }

    // MARK: - 2. Folder Location & Management Card
    private var folderLocationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(String(localized: "同步存储位置", bundle: appLocalizationBundle), systemImage: "folder.badge.gearshape")
                .font(.headline)

            if let folder = settings.folderURL {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.blue)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(folder.lastPathComponent)
                            .font(.system(size: 15, weight: .semibold))
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
                .background(Color.voxlineControlBackground.opacity(0.4), in: .rect(cornerRadius: 10))
            }
        }
        .padding(18)
        .liquidGlassSurface(cornerRadius: 14)
    }

    // MARK: - 3. Media Sync Policy Card
    private var mediaSyncPolicyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(String(localized: "原音视频媒体同步", bundle: appLocalizationBundle), systemImage: "film.stack")
                    .font(.headline)
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

            if settings.syncOriginalMedia {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                            .foregroundStyle(.blue)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "完整镜像模式（已开启原媒体同步）", bundle: appLocalizationBundle))
                                .font(.subheadline.bold())
                            Text(String(localized: "音视频文件将镜像上传至 iCloud Drive (Media/) 目录，其他登录同一 Apple 账户的设备可直接同步并播放原文件。注意：将消耗较多 iCloud 储存空间与网络流量。", bundle: appLocalizationBundle))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if settings.isCopyingOriginalMedia {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(String(localized: "正在复制并上传原音视频到云端…", bundle: appLocalizationBundle))
                                .font(.caption.bold())
                                .foregroundStyle(.blue)
                        }
                        .padding(.top, 4)
                    } else {
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
                    }
                }
                .padding(12)
                .background(Color.blue.opacity(0.08), in: .rect(cornerRadius: 10))
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "leaf.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "轻量节省模式（默认推荐）", bundle: appLocalizationBundle))
                            .font(.subheadline.bold())
                        Text(String(localized: "仅在云端同步任务清单、转写与已校对字幕。原始大文件音视频保留在本地磁盘，节省大量 iCloud 云盘容量。如需在另一台设备上播放或内封，可随时在校对页重新关联对应本地文件。", bundle: appLocalizationBundle))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(Color.green.opacity(0.08), in: .rect(cornerRadius: 10))
            }
        }
        .padding(18)
        .liquidGlassSurface(cornerRadius: 14)
    }

    // MARK: - 4. Live Sync Monitor Card
    private var liveMonitorCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(String(localized: "实时同步状态与统计", bundle: appLocalizationBundle), systemImage: "waveform.badge.magnifyingglass")
                    .font(.headline)
                Spacer()
                Button {
                    settings.refresh()
                } label: {
                    Label(String(localized: "刷新", bundle: appLocalizationBundle), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(settings.isChanging || isProcessing)
            }

            let taskCount = settings.fileStates.keys.filter { $0.pathExtension == "voxline" }.count
            let mediaCount = settings.fileStates.keys.filter { $0.pathExtension != "voxline" }.count
            let conflictCount = settings.fileStates.values.filter { $0 == .conflict }.count
            let uploadingCount = settings.fileStates.values.filter { $0 == .uploading || $0 == .waitingForUpload }.count
            let downloadingCount = settings.fileStates.values.filter { $0 == .downloading || $0 == .notDownloaded }.count

            HStack(spacing: 12) {
                statTile(title: String(localized: "任务文档", bundle: appLocalizationBundle), count: taskCount, icon: "doc.text.fill", color: .blue)
                statTile(title: String(localized: "原媒体文件", bundle: appLocalizationBundle), count: mediaCount, icon: "film.fill", color: .purple)
                statTile(title: String(localized: "传输中", bundle: appLocalizationBundle), count: uploadingCount + downloadingCount, icon: "arrow.up.arrow.down", color: .orange)
                if conflictCount > 0 {
                    statTile(title: String(localized: "冲突待解", bundle: appLocalizationBundle), count: conflictCount, icon: "exclamationmark.triangle.fill", color: .red)
                }
            }

            if conflictCount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(String(localized: "检测到 \(conflictCount) 个版本冲突文档，可在任务列表中点击“解决冲突”进行合并。", bundle: appLocalizationBundle))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .padding(10)
                .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 8))
            }
        }
        .padding(18)
        .liquidGlassSurface(cornerRadius: 14)
    }

    private func statTile(title: String, count: Int, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(color)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
            }
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.voxlineControlBackground.opacity(0.4), in: .rect(cornerRadius: 10))
    }

    // MARK: - Onboarding Card (when disabled)
    private var onboardingCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "关于 iCloud 文件夹同步", bundle: appLocalizationBundle))
                .font(.headline)

            VStack(spacing: 12) {
                featureBullet(
                    icon: "macbook.and.iphone",
                    title: String(localized: "多设备无缝接力", bundle: appLocalizationBundle),
                    description: String(localized: "在 Mac 上大批量转写并自动翻译，出门后用 iPhone 或 iPad 继续校对和微调字幕。", bundle: appLocalizationBundle)
                )
                featureBullet(
                    icon: "leaf.fill",
                    title: String(localized: "按需存储，节省空间", bundle: appLocalizationBundle),
                    description: String(localized: "默认仅同步轻量的任务结构与字幕文字，不占用庞大的 iCloud 视频存储空间。", bundle: appLocalizationBundle)
                )
                featureBullet(
                    icon: "lock.shield.fill",
                    title: String(localized: "安全私密，无需注册", bundle: appLocalizationBundle),
                    description: String(localized: "基于 Apple 原生 iCloud Drive 文件协调系统，数据仅在您个人的 iCloud 沙盒内流转。", bundle: appLocalizationBundle)
                )
            }
        }
        .padding(18)
        .liquidGlassSurface(cornerRadius: 14)
    }

    private func featureBullet(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.voxlineAccent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.voxlineControlBackground.opacity(0.3), in: .rect(cornerRadius: 10))
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
                settings.refresh()
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

    private func migrationConfirmationSheet(folder: URL, summary: TaskSyncSettings.MigrationSummary) -> some View {
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
