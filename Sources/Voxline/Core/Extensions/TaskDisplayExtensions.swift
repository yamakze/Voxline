import Foundation

public extension TaskMediaStatus {
    var isTranslationPaused: Bool {
        if case .translationPaused = self { return true }
        return false
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var isRetryable: Bool {
        switch self {
        case .failed, .interrupted, .cancelled, .translationPaused:
            return true
        default:
            return false
        }
    }

    var label: String {
        switch self {
        case .pending:
            return String(localized: "待处理", bundle: voxlineLocalizationBundle)
        case .needsTranslation:
            return String(localized: "待翻译", bundle: voxlineLocalizationBundle)
        case .running(let stage):
            return stage.label
        case .completed:
            return String(localized: "已完成", bundle: voxlineLocalizationBundle)
        case .failed(let reason):
            return String(localized: "失败：\(reason)", bundle: voxlineLocalizationBundle)
        case .translationPaused:
            return String(localized: "翻译暂停", bundle: voxlineLocalizationBundle)
        case .cancelled:
            return String(localized: "已取消", bundle: voxlineLocalizationBundle)
        case .interrupted(let stage):
            return String(localized: "已中断：\(stage.label)", bundle: voxlineLocalizationBundle)
        }
    }
}

public extension SRTOutputKind {
    var label: String {
        switch self {
        case .source:
            return String(localized: "原文", bundle: voxlineLocalizationBundle)
        case .translation:
            return String(localized: "译文", bundle: voxlineLocalizationBundle)
        case .bilingual:
            return String(localized: "双语", bundle: voxlineLocalizationBundle)
        }
    }
}

public extension ProcessingStage {
    var label: String {
        switch self {
        case .audioExtraction:
            return String(localized: "提取音频中", bundle: voxlineLocalizationBundle)
        case .transcription:
            return String(localized: "转写中", bundle: voxlineLocalizationBundle)
        case .translation:
            return String(localized: "翻译中", bundle: voxlineLocalizationBundle)
        }
    }
}

public extension ProcessingTaskStatus {
    var label: String {
        switch self {
        case .draft:
            return String(localized: "未开始", bundle: voxlineLocalizationBundle)
        case .queued:
            return String(localized: "排队中", bundle: voxlineLocalizationBundle)
        case .needsTranslation:
            return String(localized: "待翻译", bundle: voxlineLocalizationBundle)
        case .running:
            return String(localized: "处理中", bundle: voxlineLocalizationBundle)
        case .interrupted:
            return String(localized: "已中断", bundle: voxlineLocalizationBundle)
        case .completed:
            return String(localized: "已完成", bundle: voxlineLocalizationBundle)
        case .partiallyFailed:
            return String(localized: "部分失败", bundle: voxlineLocalizationBundle)
        case .failed:
            return String(localized: "失败", bundle: voxlineLocalizationBundle)
        case .translationPaused:
            return String(localized: "翻译暂停", bundle: voxlineLocalizationBundle)
        case .cancelled:
            return String(localized: "已取消", bundle: voxlineLocalizationBundle)
        }
    }
}

// MARK: - Timecode Formatter
public enum TimecodeFormatter {
    /// Formats seconds to human-readable duration, e.g. "01:57:06" or "02:35"
    public static func formatDuration(seconds: Double, alwaysIncludeHours: Bool = false) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00" }
        let totalSeconds = Int(seconds.rounded(.down))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 || alwaysIncludeHours {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }

    /// Formats milliseconds to human-readable duration, e.g. "01:57:06" or "02:35"
    public static func formatDuration(milliseconds: Int64, alwaysIncludeHours: Bool = false) -> String {
        formatDuration(seconds: Double(milliseconds) / 1000.0, alwaysIncludeHours: alwaysIncludeHours)
    }

    /// Formats milliseconds to subtitle timestamp, e.g. "00:38.260" or "01:19:44.260"
    public static func formatTimestamp(milliseconds: Int64, includeMilliseconds: Bool = true) -> String {
        guard milliseconds >= 0 else { return includeMilliseconds ? "00:00.000" : "00:00" }
        let totalSeconds = milliseconds / 1000
        let ms = milliseconds % 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            if includeMilliseconds {
                return String(format: "%02d:%02d:%02d.%03lld", hours, minutes, secs, ms)
            } else {
                return String(format: "%02d:%02d:%02d", hours, minutes, secs)
            }
        } else {
            if includeMilliseconds {
                return String(format: "%02d:%02d.%03lld", minutes, secs, ms)
            } else {
                return String(format: "%02d:%02d", minutes, secs)
            }
        }
    }
}

