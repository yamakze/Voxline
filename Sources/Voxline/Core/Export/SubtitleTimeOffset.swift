import Foundation

public enum SubtitleTimeOffset {
    public static func milliseconds(from seconds: Double) throws -> Int64 {
        let value = (seconds * 1000).rounded()
        guard value.isFinite, value >= Double(Int64.min), value < Double(Int64.max) else {
            throw SubtitleTimeOffsetError.invalidOffset
        }
        return Int64(value)
    }

    /// Validate the entire shifted timeline before replacing any editable cue.
    public static func shifted(_ cues: [SubtitleCue], by milliseconds: Int64,
                               withinDuration duration: Int64?) throws -> [SubtitleCue] {
        var shifted = cues
        for index in shifted.indices {
            let (start, startOverflow) = shifted[index].startMilliseconds.addingReportingOverflow(milliseconds)
            let (end, endOverflow) = shifted[index].endMilliseconds.addingReportingOverflow(milliseconds)
            guard !startOverflow, !endOverflow else { throw SubtitleTimeOffsetError.invalidOffset }
            guard start >= 0 else { throw SubtitleTimeOffsetError.negativeTime }
            shifted[index].startMilliseconds = start
            shifted[index].endMilliseconds = end
            if let duration, end > duration { throw ProjectValidationError.cueOutsideMedia(shifted[index].id) }
        }
        try SubtitleCue.validateTimeline(shifted, within: nil)
        return shifted
    }
}

public enum SubtitleTimeOffsetError: Error, LocalizedError, Equatable {
    case invalidOffset, negativeTime
    public var errorDescription: String? {
        switch self {
        case .invalidOffset: "偏移时间无效或超出可表示范围。"
        case .negativeTime: "偏移后部分字幕开始时间小于 0 秒。"
        }
    }
}
