import Foundation
import OSLog
import VoxlineCore

/// Shared serialization boundary for device-local evidence from both cloud protocols.
enum CloudTranscriptionEvidence {
    private static let logger = Logger(subsystem: "dev.voxline.app", category: "TranscriptionDiagnostics")

    static func recordCompleted(_ evidence: TranscriptionEvidence, to directory: URL) {
        do { _ = try write(evidence, to: directory) }
        catch { logger.error("Completed transcription diagnostics unavailable: \(error.localizedDescription)") }
    }

    static func recordResponse(_ data: Data, to directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("\(UUID()).response.json"), options: .atomic)
        } catch { logger.error("Transcription response diagnostics unavailable: \(error.localizedDescription)") }
    }

    static func write(_ evidence: TranscriptionEvidence, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID()).json")
        try TranscriptionEvidenceCodec.encode(evidence).write(to: url, options: .atomic)
        return url
    }
}
