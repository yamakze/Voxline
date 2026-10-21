import SwiftUI
import VoxlineCore
import VoxlineWorkflow

public struct TaskConflictResolutionSheet: View {
    public let taskID: UUID
    public var draftTask: ProcessingTask?
    public var onResolved: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var versions: [SharedTaskDocuments.Version] = []
    @State private var selectedVersionID: UUID?
    @State private var expandedVersionID: UUID?
    @State private var errorMessage: String?
    @State private var noticeMessage: String?
    @State private var isResolving = false

    public init(taskID: UUID, draftTask: ProcessingTask? = nil, onResolved: (() -> Void)? = nil) {
        self.taskID = taskID
        self.draftTask = draftTask
        self.onResolved = onResolved
    }

    private var library: TaskLibrary {
        #if os(macOS)
        TaskLibrary.shared
        #else
        IOSTaskLibrary.shared.storage
        #endif
    }

    private var isTaskBusy: Bool {
        library.protectedTaskID == taskID
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.orange.opacity(0.14))
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 1) {
                    Text(String(localized: "解决版本冲突", bundle: appLocalizationBundle))
                        .font(.system(size: 14, weight: .semibold))
                    Text(String(localized: "未选版本另存副本。", bundle: appLocalizationBundle))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            #if os(macOS)
            .background {
                Color(nsColor: .windowBackgroundColor).opacity(0.7)
                    .background(.regularMaterial)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.4)).frame(height: 1)
            }
            #else
            .background(.regularMaterial)
            #endif

            if let error = errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.08))
            }

            if let notice = noticeMessage {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.green)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.08))
            }

            if isTaskBusy {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.orange)
                    Text(String(localized: "任务正在处理中，暂时无法替换版本。", bundle: appLocalizationBundle))
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.08))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if versions.isEmpty && errorMessage == nil {
                        ProgressView(String(localized: "正在读取冲突版本…", bundle: appLocalizationBundle))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 40)
                    } else {
                        ForEach(versions) { version in
                            versionCard(version)
                        }
                    }
                }
                .padding(20)
            }

            HStack(spacing: 12) {
                if let draft = draftTask {
                    Button(String(localized: "草稿另存为副本", bundle: appLocalizationBundle)) {
                        saveRecoveryCopy(draft)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(isResolving)
                }

                Spacer()

                Button(String(localized: "关闭", bundle: appLocalizationBundle)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isResolving)

                Button(String(localized: "保留选定版本", bundle: appLocalizationBundle)) {
                    keepSelectedVersion()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isResolving || isTaskBusy || selectedVersionID == nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            #if os(macOS)
            .background {
                Color(nsColor: .windowBackgroundColor).opacity(0.7)
                    .background(.regularMaterial)
            }
            .overlay(alignment: .top) {
                Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.4)).frame(height: 1)
            }
            #else
            .background(.regularMaterial)
            #endif
        }
        .frame(minWidth: 540, minHeight: 480)
        .onAppear {
            loadVersions()
        }
    }

    private func versionCard(_ version: SharedTaskDocuments.Version) -> some View {
        let isSelected = selectedVersionID == version.id
        let isExpanded = expandedVersionID == version.id

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    selectedVersionID = version.id
                } label: {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.voxlineAccent : Color.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(version.origin == .localRecovery ? String(localized: "本地未上传版本", bundle: appLocalizationBundle) :
                            version.origin == .shared ? String(localized: "云端当前版本", bundle: appLocalizationBundle) : String(localized: "云端冲突版本", bundle: appLocalizationBundle))
                            .font(.headline)

                        if version.origin != .conflict {
                            Text(version.origin == .localRecovery ? String(localized: "本地", bundle: appLocalizationBundle) : String(localized: "云端", bundle: appLocalizationBundle))
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.12), in: .capsule)
                                .foregroundStyle(.blue)
                        } else {
                            Text(String(localized: "冲突副本", bundle: appLocalizationBundle))
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.12), in: .capsule)
                                .foregroundStyle(.orange)
                        }

                        Spacer()

                        if let modified = version.modifiedAt {
                            Text(modified.formatted(date: .abbreviated, time: .standard))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let device = version.deviceName {
                        Text(String(localized: "保存设备：\(device)", bundle: appLocalizationBundle))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Text(String(localized: "标题：\(version.task.title)", bundle: appLocalizationBundle))
                        Text("•")
                        Text(String(localized: "\(version.task.items.count) 个媒体", bundle: appLocalizationBundle))
                        Text("•")
                        let cuesCount = version.task.items.reduce(0) { $0 + $1.cues.count }
                        Text(String(localized: "\(cuesCount) 句字幕", bundle: appLocalizationBundle))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            expandedVersionID = isExpanded ? nil : version.id
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2.bold())
                            Text(isExpanded ? String(localized: "收起媒体详情", bundle: appLocalizationBundle) : String(localized: "预览包含的媒体与字幕", bundle: appLocalizationBundle))
                                .font(.caption)
                        }
                        .foregroundStyle(Color.voxlineAccent)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)

                    if isExpanded {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(version.task.items) { item in
                                HStack {
                                    Image(systemName: item.kind == .video ? "film" : "waveform")
                                        .font(.caption2)
                                    Text(item.title)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(String(localized: "\(item.cues.count) 句", bundle: appLocalizationBundle))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 6))
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
        .padding(14)
        .liquidGlassSurface()
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.voxlineAccent : Color.clear, lineWidth: 2)
        )
    }

    private func loadVersions() {
        errorMessage = nil
        do {
            versions = try library.conflictVersions(taskID: taskID)
            let failures = library.sharedDocuments?.versionReadErrors ?? []
            errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
            if selectedVersionID == nil {
                selectedVersionID = versions.first(where: { $0.origin == .localRecovery })?.id ?? versions.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func keepSelectedVersion() {
        guard let versionID = selectedVersionID else { return }
        guard !isTaskBusy else {
            errorMessage = String(localized: "任务正在执行，无法替换版本。", bundle: appLocalizationBundle)
            return
        }
        isResolving = true
        errorMessage = nil
        do {
            try library.keepConflictVersion(versionID, taskID: taskID)
            isResolving = false
            onResolved?()
            dismiss()
        } catch {
            isResolving = false
            errorMessage = error.localizedDescription
        }
    }

    private func saveRecoveryCopy(_ draft: ProcessingTask) {
        do {
            let copy = try library.saveRecoveryCopy(draft)
            noticeMessage = String(localized: "已将草稿另存为独立副本：“\(copy.title)”", bundle: appLocalizationBundle)
        } catch {
            errorMessage = String(localized: "另存副本失败：\(error.localizedDescription)", bundle: appLocalizationBundle)
        }
    }
}
