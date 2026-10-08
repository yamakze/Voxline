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
        case .needsReview:
            return String(localized: "待确认", bundle: voxlineLocalizationBundle)
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
        case .needsReview:
            return String(localized: "待确认", bundle: voxlineLocalizationBundle)
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
