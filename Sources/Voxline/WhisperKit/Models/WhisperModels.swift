import Foundation
import VoxlineCore

/// Model folders and tokenizer revisions published by their respective upstream repositories.
enum WhisperModels {
    static let repository = "argmaxinc/whisperkit-coreml"
    static let revision = "0f63a7800b00dd0226abd051b906c246e1907482"

    struct Model: Sendable {
        let descriptor: WhisperModelDescriptor
        let tokenizerRepository: String
        let tokenizerRevision: String
        var id: String { descriptor.id }
    }

    static let all: [Model] = [
        Model(descriptor: WhisperModelDescriptor(id: "openai_whisper-large-v3_947MB",
            name: "Whisper Large v3", description: String(localized: "高精度压缩模型", bundle: voxlineLocalizationBundle),
            expectedSizeMB: 948, isBaseline: false),
            tokenizerRepository: "openai/whisper-large-v3", tokenizerRevision: "06f233fe06e710322aca913c1bc4249a0d71fce1"),
        Model(descriptor: WhisperModelDescriptor(id: TranscriptionSettings.whisperKitBaseline.modelID,
            name: "Whisper Turbo", description: String(localized: "快速压缩模型", bundle: voxlineLocalizationBundle),
            expectedSizeMB: 627, isBaseline: true),
            tokenizerRepository: "openai/whisper-large-v3", tokenizerRevision: "06f233fe06e710322aca913c1bc4249a0d71fce1"),
        Model(descriptor: WhisperModelDescriptor(id: "openai_whisper-base",
            name: "Whisper Base", description: String(localized: "轻量模型", bundle: voxlineLocalizationBundle),
            expectedSizeMB: 147, isBaseline: false),
            tokenizerRepository: "openai/whisper-base", tokenizerRevision: "e37978b90ca9030d5170a5c07aadb050351a65bb"),
        Model(descriptor: WhisperModelDescriptor(id: "openai_whisper-small",
            name: "Whisper Small", description: String(localized: "均衡模型", bundle: voxlineLocalizationBundle),
            expectedSizeMB: 487, isBaseline: false),
            tokenizerRepository: "openai/whisper-small", tokenizerRevision: "973afd24965f72e36ca33b3055d56a652f456b4d"),
        Model(descriptor: WhisperModelDescriptor(id: "openai_whisper-tiny",
            name: "Whisper Tiny", description: String(localized: "最小模型", bundle: voxlineLocalizationBundle),
            expectedSizeMB: 77, isBaseline: false),
            tokenizerRepository: "openai/whisper-tiny", tokenizerRevision: "169d4a4341b33bc18d8881c4b69c2e104e1cc0af")
    ]

    static func model(id: String) throws -> Model {
        guard let model = all.first(where: { $0.id == id }) else { throw WhisperModelError.unknownModel }
        return model
    }
}
