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

// MARK: - Media processing steps
public struct MediaProcessingStepsView: View {
    public let item: TaskMediaItem
    public let hasTranslation: Bool
    public let provider: TranscriptionSettings.Provider?

    public init(item: TaskMediaItem, hasTranslation: Bool = true, provider: TranscriptionSettings.Provider? = nil) {
        self.item = item
        self.hasTranslation = hasTranslation
        self.provider = provider
    }

    private var status: TaskMediaStatus { item.status }

    private var transcriptionTitle: String {
        switch provider {
        case .openAICompatible: return String(localized: "云端转写", bundle: appLocalizationBundle)
        case .whisperKit: return String(localized: "本地转写", bundle: appLocalizationBundle)
        case nil: return String(localized: "语音转写", bundle: appLocalizationBundle)
        }
    }

    private var isImported: Bool { item.importedSubtitleOrigin != nil }

    private var failureReason: String? {
        if case .failed(let reason) = status {
            return reason
        }
        return nil
    }

    private var translationFailureReason: String? {
        if case .translationPaused(let reason) = status {
            return reason
        }
        return item.translationState == .failed ? failureReason : nil
    }

    public var body: some View {
        if isCompleted {
            StatusSignal(
                kind: .ready,
                accessibilityLabel: String(localized: "已就绪", bundle: appLocalizationBundle),
                help: completedSummaryTooltip
            )
            .accessibilityValue(completedSummaryTooltip)
        } else if isImported {
            HStack(spacing: 4) {
                stepChip(
                    title: String(localized: "导入原文", bundle: appLocalizationBundle),
                    state: .completed
                )

                if hasTranslation {
                    connectorLine(isActive: item.translationState != .waiting)
                    stepChip(
                        title: String(localized: "字幕翻译", bundle: appLocalizationBundle),
                        state: item.translationState,
                        failureReason: translationFailureReason
                    )
                }
            }
            .font(.caption2)
        } else {
            HStack(spacing: 4) {
                stepChip(
                    title: String(localized: "提取音频", bundle: appLocalizationBundle),
                    state: item.extractionState,
                    failureReason: item.extractionState == .failed ? failureReason : nil
                )
                connectorLine(isActive: item.transcriptionState != .waiting)
                stepChip(
                    title: transcriptionTitle,
                    state: item.transcriptionState,
                    failureReason: item.transcriptionState == .failed ? failureReason : nil
                )

                if hasTranslation {
                    connectorLine(isActive: item.translationState != .waiting)
                    stepChip(
                        title: String(localized: "字幕翻译", bundle: appLocalizationBundle),
                        state: item.translationState,
                        failureReason: translationFailureReason
                    )
                }
            }
            .font(.caption2)
        }
    }

    private var completedSummaryTooltip: String {
        if isImported {
            if hasTranslation {
                return String(localized: "导入原文 · 字幕翻译已就绪", bundle: appLocalizationBundle)
            } else {
                return String(localized: "导入原文已就绪", bundle: appLocalizationBundle)
            }
        }
        if hasTranslation {
            return String(localized: "提取音频 · \(transcriptionTitle) · 字幕翻译已就绪", bundle: appLocalizationBundle)
        } else {
            return String(localized: "提取音频 · \(transcriptionTitle)已就绪", bundle: appLocalizationBundle)
        }
    }

    private var isCompleted: Bool {
        if case .completed = status { return true }
        return false
    }

    @ViewBuilder
    private func stepChip(title: String, state: ProcessingStepState, failureReason: String? = nil) -> some View {
        let stateDescription: String = switch state {
            case .completed:
                String(localized: "已完成", bundle: appLocalizationBundle)
            case .inProgress:
                String(localized: "处理中", bundle: appLocalizationBundle)
            case .waiting:
                String(localized: "等待中", bundle: appLocalizationBundle)
            case .paused:
                String(localized: "已暂停", bundle: appLocalizationBundle)
            case .failed:
                String(localized: "失败", bundle: appLocalizationBundle)
            case .cancelled:
                String(localized: "已取消", bundle: appLocalizationBundle)
        }
        let detail = [stateDescription, failureReason].compactMap { $0 }.joined(separator: " · ")
        let signalColor: Color = switch state {
        case .completed: .green
        case .inProgress: .accentColor
        case .paused: .orange
        case .failed: .red
        case .waiting, .cancelled: .secondary
        }
        let backgroundOpacity = state == .inProgress ? 0.15 : (state == .waiting || state == .cancelled ? 0.08 : 0.12)

        HStack(spacing: 3) {
            switch state {
            case .completed:
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.green)
            case .inProgress:
                ProgressView().controlSize(.mini)
            case .waiting:
                Circle().fill(Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
            case .paused:
                Image(systemName: "pause.fill").font(.system(size: 8)).foregroundStyle(.orange)
            case .failed:
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.red)
            case .cancelled:
                Image(systemName: "minus").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            Text(title)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(signalColor.opacity(backgroundOpacity), in: .capsule)
        .foregroundStyle(state == .completed ? Color.primary : signalColor)
        .help("\(title) · \(detail)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(detail)
    }

    @ViewBuilder
    private func connectorLine(isActive: Bool) -> some View {
        Rectangle()
            .fill(isActive ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.2))
            .frame(width: 8, height: 1.5)
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
