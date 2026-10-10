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
        HStack(spacing: 5) {
            Image(systemName: iconName)
            Text(status.label)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(backgroundColor.opacity(0.15), in: .capsule)
        .foregroundStyle(foregroundColor)
    }

    private var iconName: String {
        switch status {
        case .draft: return "pencil.circle"
        case .queued: return "clock"
        case .needsTranslation: return "exclamationmark.triangle"
        case .running: return "arrow.triangle.2.circlepath.circle"
        case .interrupted, .translationPaused: return "pause.circle"
        case .completed: return "checkmark.circle.fill"
        case .partiallyFailed: return "exclamationmark.circle"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "nosign"
        }
    }

    private var backgroundColor: Color {
        if case .cancelled = status { .gray } else { foregroundColor }
    }

    private var foregroundColor: Color {
        switch status {
        case .draft: return .secondary
        case .queued: return .blue
        case .needsTranslation: return .orange
        case .running: return .blue
        case .interrupted, .translationPaused: return .orange
        case .completed: return .green
        case .partiallyFailed: return .orange
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
}

// MARK: - Media Status Badge
public struct MediaStatusBadge: View {
    public let status: TaskMediaStatus

    public init(status: TaskMediaStatus) {
        self.status = status
    }

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: iconName)
            Text(status.label)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(backgroundColor.opacity(0.15), in: .capsule)
        .foregroundStyle(foregroundColor)
    }

    private var iconName: String {
        switch status {
        case .pending: return "clock"
        case .needsTranslation: return "exclamationmark.triangle"
        case .running(let stage):
            switch stage {
            case .audioExtraction: return "waveform"
            case .transcription: return "text.bubble"
            case .translation: return "character.book.closed"
            }
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "nosign"
        case .interrupted, .translationPaused: return "pause.circle"
        }
    }

    private var backgroundColor: Color {
        if case .cancelled = status { .gray } else { foregroundColor }
    }

    private var foregroundColor: Color {
        switch status {
        case .pending: return .secondary
        case .needsTranslation: return .orange
        case .running: return .blue
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .interrupted, .translationPaused: return .orange
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

    public var body: some View {
        if isCompleted {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Text(String(localized: "全部就绪", bundle: appLocalizationBundle))
                    .font(.caption2.weight(.medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.green.opacity(0.12), in: .capsule)
            .foregroundStyle(.green)
            .help(completedSummaryTooltip)
        } else {
            HStack(spacing: 4) {
                stepChip(title: String(localized: "提取音频", bundle: appLocalizationBundle), state: item.extractionState)
                connectorLine(isActive: item.transcriptionState != .waiting)
                stepChip(title: transcriptionTitle, state: item.transcriptionState)

                if hasTranslation {
                    connectorLine(isActive: item.translationState != .waiting)
                    stepChip(title: status.isTranslationPaused ? String(localized: "翻译暂停", bundle: appLocalizationBundle) : String(localized: "字幕翻译", bundle: appLocalizationBundle), state: item.translationState)
                }

                connectorLine(isActive: isCompleted)
                stepChip(title: String(localized: "就绪", bundle: appLocalizationBundle), state: isCompleted ? .completed : (isFailed ? .failed : (isCancelled ? .cancelled : .waiting)))
            }
            .font(.caption2)
        }
    }

    private var completedSummaryTooltip: String {
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

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    private var isCancelled: Bool {
        if case .cancelled = status { return true }
        return false
    }

    @ViewBuilder
    private func stepChip(title: String, state: ProcessingStepState) -> some View {
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
        .background(
            state == .inProgress
                ? Color.accentColor.opacity(0.15)
                : (state == .completed ? Color.green.opacity(0.12) : Color.secondary.opacity(0.08)),
            in: .capsule
        )
        .foregroundStyle(state == .inProgress ? Color.accentColor : (state == .completed ? Color.primary : Color.secondary))
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
    public let state: TaskSyncSettings.FileState

    public init(state: TaskSyncSettings.FileState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
            Text(label)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(backgroundColor.opacity(0.12), in: .capsule)
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
