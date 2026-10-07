import Foundation

public enum CloudTranscriptionProtocol: String, Codable, CaseIterable, Sendable {
    case audioTranscriptions, geminiAudioChat, qwenAudioChat

    public var usesSpeechChunks: Bool { self != .audioTranscriptions }
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
              baseURL.query == nil, baseURL.fragment == nil else { throw CloudTranscriptionError.invalidConfiguration }
    }
}

public enum CloudTranscriptionError: Error, LocalizedError, Equatable {
    case invalidConfiguration, unsupportedModel, invalidResponse, uploadTooLarge, emptyAudio, audioChunkTooLong
    case incompleteResponse(String)
    case unconfiguredService, changedEndpoint
    case http(status: Int, requestID: String?)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "云端转写地址或任务配置无效。"
        case .unsupportedModel: "模型不支持当前转写协议。"
        case .invalidResponse: "转写服务返回的文本或时间戳无效。"
        case .uploadTooLarge: "转写音频超过当前服务的上传限制。"
        case .audioChunkTooLong: "音频聊天需要不超过 8 秒的语音块。"
        case .incompleteResponse(let reason): "转写响应未完整结束（\(reason)）。"
        case .emptyAudio: "待上传音频为空。"
        case .unconfiguredService: "本设备未配置任务所用的转写服务。"
        case .changedEndpoint: "转写服务地址已改变，请重新绑定任务。"
        case .http(let status, let requestID):
            "转写服务返回 HTTP \(status)" + (requestID.map { "（请求 \($0)）" } ?? "") + "。"
        }
    }
}
