import VoxlineCore
import VoxlineTranslation

public protocol SubtitleTranslationPipeline: Sendable {
    func translate(settings: TranslationSettings, request: SubtitleTranslationRequest) async throws -> [TranslationBatchOutput]
}
