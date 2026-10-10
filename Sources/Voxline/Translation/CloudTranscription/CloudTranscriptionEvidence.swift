import Foundation
import VoxlineCore

/// Shared serialization boundary for device-local evidence from both cloud protocols.
enum CloudTranscriptionEvidence {
    static func writeResponse(_ data: Data, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(UUID()).response.json"), options: .atomic)
    }

    static func write(_ evidence: TranscriptionEvidence, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID()).json")
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        try encoder.encode(evidence).write(to: url, options: .atomic)
        return url
    }
}
