import Foundation

/// Frozen destination; authentication belongs to the current device.
public struct CloudTranscriptionConfiguration: Codable, Equatable, Sendable {
    public let serviceID: UUID
    public let baseURL: URL

    public init(serviceID: UUID, baseURL: URL) {
        self.serviceID = serviceID
        self.baseURL = baseURL
    }

    public func validate() throws {
        guard ["http", "https"].contains(baseURL.scheme?.lowercased()),
              baseURL.host?.isEmpty == false, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else { throw CloudTranscriptionError.invalidConfiguration }
    }
}

public enum CloudTranscriptionError: Error, LocalizedError, Equatable {
    case invalidConfiguration, unsupportedModel, invalidResponse, uploadTooLarge, emptyAudio
    case unconfiguredService, changedEndpoint
    case http(status: Int, requestID: String?)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "云端转写地址或任务配置无效。"
        case .unsupportedModel: "当前转写协议仅支持 whisper-1 的分段时间戳。"
        case .invalidResponse: "转写服务未返回有效的分段时间戳。"
        case .uploadTooLarge: "单次转写音频超过 25 MB。"
        case .emptyAudio: "待上传音频为空。"
        case .unconfiguredService: "本设备未配置任务所用的转写服务。"
        case .changedEndpoint: "转写服务地址已改变，请重新绑定任务。"
        case .http(let status, let requestID):
            "转写服务返回 HTTP \(status)" + (requestID.map { "（请求 \($0)）" } ?? "") + "。"
        }
    }
}
