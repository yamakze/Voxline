import Foundation

public struct SubtitleDisplayInterval: Equatable, Sendable {
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let cueIndices: [Int]
}

/// A sweep built once per edited snapshot. Queries never scan the subtitle document.
public struct SubtitleTimeline: Sendable {
    public let intervals: [SubtitleDisplayInterval]

    public init(cues: [SubtitleCue]) {
        self.init(ranges: cues.map { ($0.startMilliseconds, $0.endMilliseconds) })
    }

    public init(ranges: [(start: Int64, end: Int64)]) {
        var changes: [Int64: (starting: [Int], ending: [Int])] = [:]
        for (index, range) in ranges.enumerated() {
            changes[range.start, default: ([], [])].starting.append(index)
            changes[range.end, default: ([], [])].ending.append(index)
        }
        let times = changes.keys.sorted()
        var active = Set<Int>()
        var result: [SubtitleDisplayInterval] = []
        for (index, time) in times.enumerated() {
            let change = changes[time]!
            active.subtract(change.ending)
            active.formUnion(change.starting)
            if index + 1 < times.count, !active.isEmpty {
                result.append(.init(startMilliseconds: time, endMilliseconds: times[index + 1], cueIndices: active.sorted()))
            }
        }
        intervals = result
    }

    public func interval(atMilliseconds time: Int64) -> SubtitleDisplayInterval? {
        var lower = 0, upper = intervals.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if intervals[middle].startMilliseconds <= time { lower = middle + 1 } else { upper = middle }
        }
        guard lower > 0, time < intervals[lower - 1].endMilliseconds else { return nil }
        return intervals[lower - 1]
    }
}
