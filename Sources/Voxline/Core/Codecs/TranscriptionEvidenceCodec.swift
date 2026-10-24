import Foundation

/// Diagnostic evidence preserves non-finite alignment values for later analysis.
public enum TranscriptionEvidenceCodec {
    public static func encode(_ evidence: TranscriptionEvidence) throws -> Data {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return try encoder.encode(evidence)
    }
}
