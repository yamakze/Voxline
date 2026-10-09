import Foundation

public enum CloudTranscriptionProtocol: String, Codable, CaseIterable, Sendable {
    case audioTranscriptions, geminiAudioChat, qwenAudioChat

    public var usesSpeechChunks: Bool { self != .audioTranscriptions }

    public var label: String {
        switch self {
        case .audioTranscriptions: "Audio Transcriptions"
        case .geminiAudioChat: String(localized: "Gemini 音频聊天", bundle: voxlineLocalizationBundle)
        case .qwenAudioChat: String(localized: "百炼音频聊天", bundle: voxlineLocalizationBundle)
        }
    }
}

/// Frozen destination; authentication belongs to the current device.
public struct CloudTranscriptionConfiguration: Codable, Equatable, Sendable {
    public let serviceID: UUID
    public let baseURL: URL
    public let protocolKind: CloudTranscriptionProtocol

    public init(serviceID: UUID, baseURL: URL, protocolKind: CloudTranscriptionProtocol = .audioTranscriptions) {
        self.serviceID = serviceID
        self.baseURL = baseURL
        self.protocolKind = protocolKind
    }

    private enum CodingKeys: String, CodingKey { case serviceID, baseURL, protocolKind }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        serviceID = try values.decode(UUID.self, forKey: .serviceID)
        baseURL = try values.decode(URL.self, forKey: .baseURL)
        // Existing documents predate multi-protocol support and use Audio Transcriptions.
        protocolKind = try values.decodeIfPresent(CloudTranscriptionProtocol.self, forKey: .protocolKind) ?? .audioTranscriptions
    }

    public func validate() throws {
        guard ["http", "https"].contains(baseURL.scheme?.lowercased()),
              baseURL.host?.isEmpty == false, baseURL.user == nil, baseURL.password == nil,
              baseURL.fragment == nil else { throw CloudTranscriptionError.invalidConfiguration }
    }
}

public enum CloudTranscriptionError: Error, LocalizedError, Equatable {
    case invalidConfiguration, invalidResponse, uploadTooLarge, emptyAudio, audioChunkTooLong
    case incompleteResponse(String)
    case unconfiguredService, changedEndpoint
    case http(status: Int, requestID: String?)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: String(localized: "云端转写地址或任务配置无效。", bundle: voxlineLocalizationBundle)
        case .invalidResponse: String(localized: "转写服务返回的文本或时间戳无效。", bundle: voxlineLocalizationBundle)
        case .uploadTooLarge: String(localized: "转写音频超过当前服务的上传限制。", bundle: voxlineLocalizationBundle)
        case .audioChunkTooLong: String(localized: "音频聊天需要不超过 8 秒的语音块。", bundle: voxlineLocalizationBundle)
        case .incompleteResponse(let reason): String(localized: "转写响应未完整结束（\(reason)）。", bundle: voxlineLocalizationBundle)
        case .emptyAudio: String(localized: "待上传音频为空。", bundle: voxlineLocalizationBundle)
        case .unconfiguredService: String(localized: "本设备未配置任务所用的转写服务。", bundle: voxlineLocalizationBundle)
        case .changedEndpoint: String(localized: "转写服务地址已改变，请重新绑定任务。", bundle: voxlineLocalizationBundle)
        case .http(let status, let requestID):
            if let requestID {
                String(localized: "转写服务返回 HTTP \(status)（请求 \(requestID)）。", bundle: voxlineLocalizationBundle)
            } else { String(localized: "转写服务返回 HTTP \(status)。", bundle: voxlineLocalizationBundle) }
        }
    }
}
