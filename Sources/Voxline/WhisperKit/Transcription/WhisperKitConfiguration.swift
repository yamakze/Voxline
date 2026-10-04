import Foundation
import VoxlineCore
import WhisperKit

/// SDK configuration stays inside the integration target. It does not indicate that model assets are ready.
enum WhisperKitConfiguration {
    static func localModel(at directory: URL, settings: TranscriptionSettings) throws -> WhisperKitConfig {
        try settings.validate()
        guard directory.isFileURL else { throw WhisperKitConfigurationError.nonlocalModelDirectory }
        return WhisperKitConfig(
            model: settings.modelID, modelFolder: directory.path,
            computeOptions: ModelComputeOptions(audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine),
            verbose: false, logLevel: .error, prewarm: false, load: true, download: false)
    }
}

enum WhisperKitConfigurationError: Error { case nonlocalModelDirectory }
