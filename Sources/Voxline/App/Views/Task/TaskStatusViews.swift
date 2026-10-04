import SwiftUI
import VoxlineCore

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
        case .needsReview: return "exclamationmark.triangle"
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
        case .needsReview: return .orange
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
        case .needsReview: return "exclamationmark.triangle"
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
        case .needsReview: return .orange
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

    public init(item: TaskMediaItem, hasTranslation: Bool = true) {
        self.item = item
        self.hasTranslation = hasTranslation
    }

    private var status: TaskMediaStatus { item.status }

    public var body: some View {
        HStack(spacing: 4) {
            stepChip(title: "提取音频", state: item.extractionState)
            connectorLine(isActive: item.transcriptionState != .waiting)
            stepChip(title: "本地转写", state: item.transcriptionState)

            if hasTranslation {
                connectorLine(isActive: item.translationState != .waiting)
                stepChip(title: status.isTranslationPaused ? "翻译暂停" : "字幕翻译", state: item.translationState)
            }

            connectorLine(isActive: isCompleted)
            stepChip(title: "就绪", state: isCompleted ? .completed : (isFailed ? .failed : (isCancelled ? .cancelled : .waiting)))
        }
        .font(.caption2)
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
