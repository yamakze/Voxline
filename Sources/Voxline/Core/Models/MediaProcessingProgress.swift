import Foundation

public enum ProcessingStepState: Sendable {
    case completed, inProgress, waiting, paused, failed, cancelled
}

public extension TaskMediaItem {
    var extractionState: ProcessingStepState {
        if status == .running(stage: .audioExtraction) { return .inProgress }
        if checkpoint != nil { return .completed }
        switch status {
        case .pending: return .waiting
        case .running(let stage):
            return stage == .audioExtraction ? .inProgress : .completed
        case .completed, .needsTranslation, .translationPaused: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .interrupted(let stage):
            return stage == .audioExtraction ? .paused : .completed
        }
    }

    var transcriptionState: ProcessingStepState {
        if let checkpoint, checkpoint.chunks.allSatisfy(\.isCompleted) {
            return .completed
        }
        switch status {
        case .pending: return .waiting
        case .running(let stage):
            if stage == .audioExtraction { return .waiting }
            if stage == .transcription { return .inProgress }
            return .completed
        case .completed, .needsTranslation, .translationPaused: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .interrupted(let stage):
            if stage == .audioExtraction { return .waiting }
            if stage == .transcription { return .paused }
            return .completed
        }
    }

    var translationState: ProcessingStepState {
        if status.isRetryable, checkpoint?.chunks.allSatisfy(\.isCompleted) != true {
            return .waiting
        }
        switch status {
        case .pending: return .waiting
        case .running(let stage):
            return stage == .translation ? .inProgress : .waiting
        case .completed: return .completed
        case .needsTranslation: return .waiting
        case .translationPaused: return .paused
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .interrupted(let stage):
            return stage == .translation ? .paused : .waiting
        }
    }
}
