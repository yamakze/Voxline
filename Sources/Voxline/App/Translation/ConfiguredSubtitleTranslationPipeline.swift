import Foundation
import VoxlineCore
import VoxlineTranslation

import VoxlineWorkflow

struct ConfiguredSubtitleTranslationPipeline: SubtitleTranslationPipeline {
    let client: OpenAICompatibleTranslationClient
    init(client: OpenAICompatibleTranslationClient = .init()) { self.client = client }

    func translate(settings: TranslationSettings, request: SubtitleTranslationRequest) async throws -> [TranslationBatchOutput] {
        switch settings.engine {
        case .openAICompatible:
            let key = try await TranslationServiceStore.shared.apiKey(for: settings)
            return try await client.translate(settings: settings, apiKey: key, request: request)
        case .appleTranslation:
            return try await AppleTranslationCoordinator.shared.translate(settings: settings, request: request)
        }
    }
}
