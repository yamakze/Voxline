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
        // Empty or reversed ranges have no display interval. Domain validation owns their errors.
        for (index, range) in ranges.enumerated() where range.end > range.start {
            changes[range.start, default: ([], [])].starting.append(index)
            changes[range.end, default: ([], [])].ending.append(index)
        }
        let events = changes.sorted { $0.key < $1.key }
        var active = Set<Int>()
        var result: [SubtitleDisplayInterval] = []
        for (index, event) in events.enumerated() {
            let (time, change) = event
            active.subtract(change.ending)
            active.formUnion(change.starting)
            if index + 1 < events.count, !active.isEmpty {
                result.append(.init(startMilliseconds: time, endMilliseconds: events[index + 1].key, cueIndices: active.sorted()))
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

    public func cueIndices(overlappingStart start: Int64, end: Int64) -> [Int] {
        var lower = 0, upper = intervals.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if intervals[middle].endMilliseconds <= start { lower = middle + 1 } else { upper = middle }
        }
        var indices = Set<Int>()
        while lower < intervals.count, intervals[lower].startMilliseconds < end {
            indices.formUnion(intervals[lower].cueIndices)
            lower += 1
        }
        return indices.sorted()
    }
}
