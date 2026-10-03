import Foundation
import VoxlineCore
import VoxlineTranslation

protocol SubtitleTranslationPipeline: Sendable {
    func translate(settings: TranslationSettings, request: SubtitleTranslationRequest) async throws -> [TranslationBatchOutput]
}

struct LocalSubtitleTranslationPipeline: SubtitleTranslationPipeline {
    let client: OpenAICompatibleTranslationClient
    init(client: OpenAICompatibleTranslationClient = .init()) { self.client = client }

    func translate(settings: TranslationSettings, request: SubtitleTranslationRequest) async throws -> [TranslationBatchOutput] {
        let key = try await TranslationServiceStore.shared.apiKey(for: settings)
        return try await client.translate(settings: settings, apiKey: key, request: request)
    }
}
