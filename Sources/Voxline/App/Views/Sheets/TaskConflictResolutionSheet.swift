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
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("解决版本冲突")
                        .font(.headline)
                    Text("选择保留的主版本，未选版本将解除冲突标记。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isResolving)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.regularMaterial)

            Divider()

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
                    Text("任务正在处理中，暂时无法替换版本。")
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
                    if versions.isEmpty {
                        ProgressView("正在读取冲突版本…")
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

            Divider()

            HStack(spacing: 12) {
                if let draft = draftTask {
                    Button("草稿另存为副本") {
                        saveRecoveryCopy(draft)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(isResolving)
                }

                Spacer()

                Button("关闭") { dismiss() }
                    .disabled(isResolving)

                Button("保留选定版本") {
                    keepSelectedVersion()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isResolving || isTaskBusy || selectedVersionID == nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial)
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
                        Text(version.isCurrent ? "当前设备版本" : "云端冲突版本")
                            .font(.headline)

                        if version.isCurrent {
                            Text("本地")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.12), in: .capsule)
                                .foregroundStyle(.blue)
                        } else {
                            Text("冲突副本")
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
                        Text("保存设备：\(device)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Text("标题：\(version.task.title)")
                        Text("•")
                        Text("\(version.task.items.count) 个媒体")
                        Text("•")
                        let cuesCount = version.task.items.reduce(0) { $0 + $1.cues.count }
                        Text("\(cuesCount) 句字幕")
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
                            Text(isExpanded ? "收起媒体详情" : "预览包含的媒体与字幕")
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
                                    Text("\(item.cues.count) 句")
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
            if selectedVersionID == nil {
                selectedVersionID = versions.first(where: { $0.isCurrent })?.id ?? versions.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func keepSelectedVersion() {
        guard let versionID = selectedVersionID else { return }
        guard !isTaskBusy else {
            errorMessage = "任务正在执行，无法替换版本。"
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
            noticeMessage = "已将草稿另存为独立副本：“\(copy.title)”"
        } catch {
            errorMessage = "另存副本失败：\(error.localizedDescription)"
        }
    }
}
