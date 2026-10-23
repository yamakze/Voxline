import SwiftUI
import VoxlineCore
import VoxlineWhisperKit

/// Visual semantics shared by task and model status indicators.
public enum StatusSignalKind: Equatable, Sendable {
    case ready          // 就绪 / 已完成
    case waiting        // 等待 / 排队 / 草稿
    case notDownloaded
    case running        // 处理中 / 运行中 / 下载中
    case paused         // 暂停 / 中断 / 待恢复
    case cancelled      // 取消 / 已终止
    case failed         // 失败 / 错误 / 损坏

    public var tintColor: Color {
        switch self {
        case .ready:
            return .green
        case .waiting, .notDownloaded:
            return .secondary
        case .running:
            return .blue
        case .paused:
            return .orange
        case .cancelled:
            return .secondary
        case .failed:
            return .red
        }
    }

    public var defaultLabel: String {
        switch self {
        case .ready:
            return String(localized: "已就绪", bundle: appLocalizationBundle)
        case .waiting:
            return String(localized: "等待中", bundle: appLocalizationBundle)
        case .notDownloaded:
            return String(localized: "未下载", bundle: appLocalizationBundle)
        case .running:
            return String(localized: "处理中", bundle: appLocalizationBundle)
        case .paused:
            return String(localized: "已暂停", bundle: appLocalizationBundle)
        case .cancelled:
            return String(localized: "已取消", bundle: appLocalizationBundle)
        case .failed:
            return String(localized: "失败", bundle: appLocalizationBundle)
        }
    }

    public init(taskStatus: ProcessingTaskStatus) {
        switch taskStatus {
        case .completed:
            self = .ready
        case .draft, .queued:
            self = .waiting
        case .running:
            self = .running
        case .needsTranslation, .interrupted, .translationPaused:
            self = .paused
        case .cancelled:
            self = .cancelled
        case .partiallyFailed, .failed:
            self = .failed
        }
    }

    public init(mediaStatus: TaskMediaStatus) {
        switch mediaStatus {
        case .completed:
            self = .ready
        case .pending:
            self = .waiting
        case .running:
            self = .running
        case .needsTranslation, .interrupted, .translationPaused:
            self = .paused
        case .cancelled:
            self = .cancelled
        case .failed:
            self = .failed
        }
    }

    public init(modelStatus: ModelStatus) {
        switch modelStatus {
        case .ready:
            self = .ready
        case .notDownloaded:
            self = .notDownloaded
        case .downloading, .checking, .cancelling:
            self = .running
        case .cancelled:
            self = .cancelled
        case .failed, .corrupted:
            self = .failed
        }
    }
}

/// A compact status symbol with a text equivalent for accessibility and hover help.
public struct StatusSignal: View {
    public let kind: StatusSignalKind
    public let accessibilityLabelText: String?
    public let helpText: String?

    public init(
        kind: StatusSignalKind,
        accessibilityLabel: String? = nil,
        help: String? = nil
    ) {
        self.kind = kind
        self.accessibilityLabelText = accessibilityLabel
        self.helpText = help
    }

    public init(taskStatus: ProcessingTaskStatus) {
        self.init(kind: StatusSignalKind(taskStatus: taskStatus), accessibilityLabel: taskStatus.label)
    }

    public init(mediaStatus: TaskMediaStatus) {
        self.init(kind: StatusSignalKind(mediaStatus: mediaStatus), accessibilityLabel: mediaStatus.label)
    }

    public init(modelStatus: ModelStatus) {
        self.init(kind: StatusSignalKind(modelStatus: modelStatus), accessibilityLabel: modelStatus.label)
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(kind.tintColor.opacity(0.12))

            Circle()
                .strokeBorder(kind.tintColor.opacity(0.24), lineWidth: 0.8)

            iconView
        }
        .frame(width: 20, height: 20)
        .help(helpText ?? accessibilityLabelText ?? kind.defaultLabel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelText ?? kind.defaultLabel)
    }

    @ViewBuilder
    private var iconView: some View {
        switch kind {
        case .ready:
            Image(systemName: "checkmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Color.green)
        case .waiting:
            Image(systemName: "clock")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(Color.secondary)
        case .notDownloaded:
            Image(systemName: "arrow.down")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(Color.secondary)
        case .running:
            ProgressView()
                .controlSize(.mini)
                .tint(Color.blue)
        case .paused:
            Image(systemName: "pause.fill")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(Color.orange)
        case .cancelled:
            Image(systemName: "nosign")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Color.secondary)
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Color.red)
        }
    }

}
