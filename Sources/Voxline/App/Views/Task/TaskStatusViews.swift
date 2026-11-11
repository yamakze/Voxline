import SwiftUI
import VoxlineCore
import VoxlineWorkflow

// MARK: - Task Status Badge
public struct TaskStatusBadge: View {
    public let status: ProcessingTaskStatus

    public init(status: ProcessingTaskStatus) {
        self.status = status
    }

    public var body: some View {
        StatusSignal(taskStatus: status)
    }
}

// MARK: - Media Status Badge
public struct MediaStatusBadge: View {
    public let status: TaskMediaStatus

    public init(status: TaskMediaStatus) {
        self.status = status
    }

    public var body: some View {
        HStack(spacing: 6) {
            StatusSignal(mediaStatus: status)
            if case .running(let stage) = status {
                Text(stage.label).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Sync File Status Badge
public struct SyncFileStatusBadge: View {
    public let state: TaskSyncCoordinator.FileState

    public init(state: TaskSyncCoordinator.FileState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
            Text(label)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(backgroundColor.opacity(0.12), in: .capsule)
        #if os(macOS)
        .overlay(
            Capsule()
                .strokeBorder(foregroundColor.opacity(0.25), lineWidth: 0.8)
        )
        #endif
        .foregroundStyle(foregroundColor)
    }

    private var label: String {
        switch state {
        case .available: return String(localized: "可用", bundle: appLocalizationBundle)
        case .waitingForUpload: return String(localized: "等待上传", bundle: appLocalizationBundle)
        case .uploading: return String(localized: "上传中", bundle: appLocalizationBundle)
        case .notDownloaded: return String(localized: "云端占位", bundle: appLocalizationBundle)
        case .downloading: return String(localized: "下载中", bundle: appLocalizationBundle)
        case .synced: return String(localized: "已同步", bundle: appLocalizationBundle)
        case .conflict: return String(localized: "版本冲突", bundle: appLocalizationBundle)
        case .failed(let reason): return String(localized: "同步失败：\(reason)", bundle: appLocalizationBundle)
        }
    }

    private var iconName: String {
        switch state {
        case .available: return "doc"
        case .waitingForUpload: return "arrow.up.circle"
        case .uploading: return "arrow.up.circle.fill"
        case .notDownloaded: return "icloud.and.arrow.down"
        case .downloading: return "arrow.down.circle.fill"
        case .synced: return "checkmark.icloud.fill"
        case .conflict: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private var foregroundColor: Color {
        switch state {
        case .available, .waitingForUpload: return .secondary
        case .uploading, .downloading: return .blue
        case .synced: return .green
        case .notDownloaded, .conflict: return .orange
        case .failed: return .red
        }
    }

    private var backgroundColor: Color { foregroundColor }
}

struct TaskQueueProgress: View {
    let taskID: UUID
    let mediaID: UUID
    let queue: TaskProcessingQueue

    var body: some View {
        if queue.taskID == taskID, queue.mediaID == mediaID {
            VStack(alignment: .leading, spacing: 4) {
                Text(queue.isCancelling ? String(localized: "正在取消，等待当前操作结束", bundle: appLocalizationBundle) : queue.progressText ?? String(localized: "处理中", bundle: appLocalizationBundle))
                    .foregroundStyle(.tint)
                if let wait = queue.translationRetryWait, !queue.isCancelling {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(wait.label(at: context.date)).monospacedDigit()
                    }
                }
                if let fraction = queue.extractionFraction {
                    ProgressView(value: fraction).frame(maxWidth: 180)
                }
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TaskFailureDisclosure: View {
    let message: String
    let tint: Color

    var body: some View {
        DisclosureGroup {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label {
                Text(message).lineLimit(1)
            } icon: {
                Image(systemName: "exclamationmark.circle").foregroundStyle(tint)
            }
            .font(.callout)
        }
        .tint(tint)
    }
}
