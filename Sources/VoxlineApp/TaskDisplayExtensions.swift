import SwiftUI
import VoxlineCore

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
            return "待处理"
        case .needsReview:
            return "待确认"
        case .running(let stage):
            return stage.label
        case .completed:
            return "已完成"
        case .failed(let reason):
            return "失败：\(reason)"
        case .translationPaused:
            return "翻译暂停"
        case .cancelled:
            return "已取消"
        case .interrupted(let stage):
            return "已中断：\(stage.label)"
        }
    }
}

public extension SRTOutputKind {
    var label: String {
        switch self {
        case .source:
            return "原文"
        case .translation:
            return "译文"
        case .bilingual:
            return "双语"
        }
    }
}

public extension ProcessingStage {
    var label: String {
        switch self {
        case .audioExtraction:
            return "提取音频中"
        case .transcription:
            return "转写中"
        case .translation:
            return "翻译中"
        }
    }
}

public extension ProcessingTaskStatus {
    var label: String {
        switch self {
        case .draft:
            return "未开始"
        case .queued:
            return "排队中"
        case .needsReview:
            return "待确认"
        case .running:
            return "处理中"
        case .interrupted:
            return "已中断"
        case .completed:
            return "已完成"
        case .partiallyFailed:
            return "部分失败"
        case .failed:
            return "失败"
        case .translationPaused:
            return "翻译暂停"
        case .cancelled:
            return "已取消"
        }
    }
}
