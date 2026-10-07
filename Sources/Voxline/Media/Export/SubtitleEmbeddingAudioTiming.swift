import AVFoundation
import Foundation

/// Preserve legacy AAC's implicit priming when AssetWriter adds a zero-origin edit.
/// Only movie metadata is changed; encoded packets and their file offsets stay intact.
enum SubtitleEmbeddingAudioTiming {
    static func preserveImplicitPriming(_ priming: CMTime, from source: URL, audioTrackID: CMPersistentTrackID, in output: URL) throws {
        let original = try FileHandle(forReadingFrom: source)
        defer { try? original.close() }
        let (_, sourceMovie) = try movieHeader(original)
        let sourceTracks = try boxes(sourceMovie, in: 0..<sourceMovie.count).filter { $0.type == "trak" }
        guard let sourceTrack = try sourceTracks.first(where: { track in
            guard let header = try boxes(sourceMovie, in: track.body).first(where: { $0.type == "tkhd" }) else { return false }
            let version = try unsigned(sourceMovie, at: header.body.lowerBound, count: 1)
            return try unsigned(sourceMovie, at: header.body.lowerBound + (version == 1 ? 20 : 12), count: 4) == UInt64(audioTrackID)
        }) else { throw SubtitleEmbeddingError.invalidOutput }
        // Explicit source edits remain under the normal passthrough validation rules.
        if try boxes(sourceMovie, in: sourceTrack.body).contains(where: { $0.type == "edts" }) { return }

        let file = try FileHandle(forUpdating: output)
        defer { try? file.close() }
        let (base, movie) = try movieHeader(file)
        let children = try boxes(movie, in: 0..<movie.count)
        guard let movieHeader = children.first(where: { $0.type == "mvhd" }) else { throw SubtitleEmbeddingError.invalidOutput }
        let movieVersion = try unsigned(movie, at: movieHeader.body.lowerBound, count: 1)
        guard movieVersion <= 1 else { throw SubtitleEmbeddingError.invalidOutput }
        let movieScale = try unsigned(movie, at: movieHeader.body.lowerBound + (movieVersion == 1 ? 20 : 12), count: 4)
        guard let movieTimeScale = Int32(exactly: movieScale), movieTimeScale > 0 else { throw SubtitleEmbeddingError.invalidOutput }
        for track in children where track.type == "trak" {
            let trackChildren = try boxes(movie, in: track.body)
            guard let media = trackChildren.first(where: { $0.type == "mdia" }) else { continue }
            let mediaChildren = try boxes(movie, in: media.body)
            guard let handler = mediaChildren.first(where: { $0.type == "hdlr" }), handler.body.count >= 12,
                  movie[(handler.body.lowerBound + 8)..<(handler.body.lowerBound + 12)] == Data("soun".utf8) else { continue }
            guard let mediaHeader = mediaChildren.first(where: { $0.type == "mdhd" }),
                  let trackHeader = trackChildren.first(where: { $0.type == "tkhd" }),
                  let edits = trackChildren.first(where: { $0.type == "edts" }),
                  let list = try boxes(movie, in: edits.body).first(where: { $0.type == "elst" }), list.body.count >= 8 else { throw SubtitleEmbeddingError.invalidOutput }
            let mediaVersion = try unsigned(movie, at: mediaHeader.body.lowerBound, count: 1)
            let trackVersion = try unsigned(movie, at: trackHeader.body.lowerBound, count: 1)
            let editVersion = try unsigned(movie, at: list.body.lowerBound, count: 1)
            guard mediaVersion <= 1, trackVersion <= 1, editVersion <= 1,
                  try unsigned(movie, at: list.body.lowerBound + 4, count: 4) == 1 else { throw SubtitleEmbeddingError.unsupportedFormat }
            let mediaScale = try unsigned(movie, at: mediaHeader.body.lowerBound + (mediaVersion == 1 ? 20 : 12), count: 4)
            guard let mediaTimeScale = Int32(exactly: mediaScale), mediaTimeScale > 0,
                  priming == CMTime(value: 2112, timescale: mediaTimeScale) else { throw SubtitleEmbeddingError.unsupportedFormat }
            let origin = list.body.lowerBound + (editVersion == 1 ? 16 : 12), width = editVersion == 1 ? 8 : 4
            guard try unsigned(movie, at: origin, count: width) == 0,
                  try unsigned(movie, at: origin + width, count: 4) == 0x0001_0000 else { throw SubtitleEmbeddingError.unsupportedFormat }
            let mediaDuration = try unsigned(movie, at: mediaHeader.body.lowerBound + (mediaVersion == 1 ? 24 : 16), count: mediaVersion == 1 ? 8 : 4)
            guard let durationValue = Int64(exactly: mediaDuration) else { throw SubtitleEmbeddingError.invalidOutput }
            let rawDuration = CMTimeConvertScale(CMTime(value: durationValue, timescale: mediaTimeScale), timescale: movieTimeScale, method: .roundAwayFromZero).value
            guard rawDuration > 0 else { throw SubtitleEmbeddingError.invalidOutput }
            // Without an edit, track duration includes priming, matching the source representation.
            try write(UInt64(rawDuration), width: trackVersion == 1 ? 8 : 4,
                at: base + UInt64(trackHeader.body.lowerBound + (trackVersion == 1 ? 28 : 20)), to: file)
            let movieDurationOffset = movieHeader.body.lowerBound + (movieVersion == 1 ? 24 : 16)
            let movieDuration = try unsigned(movie, at: movieDurationOffset, count: movieVersion == 1 ? 8 : 4)
            if movieDuration < UInt64(rawDuration) {
                try write(UInt64(rawDuration), width: movieVersion == 1 ? 8 : 4, at: base + UInt64(movieDurationOffset), to: file)
            }
            try file.seek(toOffset: base + UInt64(edits.body.lowerBound - 4))
            try file.write(contentsOf: Data("free".utf8))
            return
        }
        throw SubtitleEmbeddingError.invalidOutput
    }

    private static func movieHeader(_ file: FileHandle) throws -> (UInt64, Data) {
        let length = try file.seekToEnd()
        var offset: UInt64 = 0
        while offset + 8 <= length {
            try file.seek(toOffset: offset)
            let header = try file.read(upToCount: 16) ?? Data()
            guard header.count >= 8 else { throw SubtitleEmbeddingError.invalidOutput }
            let smallSize = try unsigned(header, at: 0, count: 4)
            let headerSize: UInt64 = smallSize == 1 ? 16 : 8
            let size = smallSize == 1 ? try unsigned(header, at: 8, count: 8) : (smallSize == 0 ? length - offset : smallSize)
            guard size >= headerSize, size <= length - offset else { throw SubtitleEmbeddingError.invalidOutput }
            if header[4..<8] == Data("moov".utf8) {
                try file.seek(toOffset: offset + headerSize)
                let body = try file.read(upToCount: Int(size - headerSize)) ?? Data()
                guard body.count == Int(size - headerSize) else { throw SubtitleEmbeddingError.invalidOutput }
                return (offset + headerSize, body)
            }
            offset += size
        }
        throw SubtitleEmbeddingError.invalidOutput
    }

    private struct Box {
        let type: String
        let body: Range<Int>
    }

    private static func boxes(_ data: Data, in range: Range<Int>) throws -> [Box] {
        var result: [Box] = [], offset = range.lowerBound
        while offset < range.upperBound {
            guard range.upperBound - offset >= 8 else { throw SubtitleEmbeddingError.invalidOutput }
            let smallSize = try unsigned(data, at: offset, count: 4)
            let headerSize = smallSize == 1 ? 16 : 8
            let size = smallSize == 1 ? try unsigned(data, at: offset + 8, count: 8) : (smallSize == 0 ? UInt64(range.upperBound - offset) : smallSize)
            guard size >= headerSize, size <= range.upperBound - offset else { throw SubtitleEmbeddingError.invalidOutput }
            result.append(Box(type: String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self), body: (offset + headerSize)..<(offset + Int(size))))
            offset += Int(size)
        }
        return result
    }

    private static func unsigned(_ data: Data, at offset: Int, count: Int) throws -> UInt64 {
        guard offset >= 0, offset <= data.count, count <= data.count - offset else { throw SubtitleEmbeddingError.invalidOutput }
        return data[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private static func write(_ value: UInt64, width: Int, at offset: UInt64, to file: FileHandle) throws {
        guard width == 8 || value <= UInt32.max else { throw SubtitleEmbeddingError.unsupportedFormat }
        var bytes = Data()
        for shift in stride(from: (width - 1) * 8, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) }
        try file.seek(toOffset: offset); try file.write(contentsOf: bytes)
    }
}
