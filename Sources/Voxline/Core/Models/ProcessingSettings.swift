import Foundation

public struct MediaIdentity: Codable, Equatable, Sendable {
    public let fileName: String
    public let byteCount: Int64
    public let fingerprint: String
    public let durationMilliseconds: Int64
    public let audioTrackID: Int32

    public init(fileName: String, byteCount: Int64, fingerprint: String, durationMilliseconds: Int64, audioTrackID: Int32) throws {
        self.fileName = fileName
        self.byteCount = byteCount
        self.fingerprint = fingerprint
        self.durationMilliseconds = durationMilliseconds
        self.audioTrackID = audioTrackID
        try validate()
    }

    public func validate() throws {
        guard !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !fileName.contains("/"), !fileName.contains("\\"), byteCount > 0, durationMilliseconds > 0,
              audioTrackID != 0, fingerprint.utf8.count == 64,
              fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ProjectValidationError.invalidMediaIdentity
        }
    }

    public func matchesContent(of other: MediaIdentity) -> Bool {
        byteCount == other.byteCount && fingerprint == other.fingerprint &&
        durationMilliseconds == other.durationMilliseconds && audioTrackID == other.audioTrackID
    }
}

public struct TranscriptionSettings: Codable, Equatable, Sendable {
    public enum Provider: String, Codable, Sendable { case whisperKit, openAICompatible }
    public enum LanguageMode: String, Codable, Sendable { case automatic, specified }
    public let provider: Provider
    public let modelID: String
    public let languageMode: LanguageMode
    public let languageCode: String?
    public let cloud: CloudTranscriptionConfiguration?

    public init(provider: Provider = .whisperKit, modelID: String,
                languageMode: LanguageMode = .automatic, languageCode: String? = nil, cloud: CloudTranscriptionConfiguration? = nil) {
        self.provider = provider
        self.modelID = modelID
        self.languageMode = languageMode
        self.languageCode = languageCode
        self.cloud = cloud
    }

    public static let whisperKitBaseline = TranscriptionSettings(
        provider: .whisperKit, modelID: "openai_whisper-large-v3-v20240930_626MB", languageMode: .automatic)

    public func validate() throws {
        switch provider {
        case .whisperKit:
            guard cloud == nil else { throw CloudTranscriptionError.invalidConfiguration }
        case .openAICompatible:
            guard let cloud else { throw CloudTranscriptionError.invalidConfiguration }
            try cloud.validate()
            // This protocol requires verbose segment timestamps; newer text-only models use another protocol.
            if cloud.protocolKind == .audioTranscriptions, modelID != "whisper-1" {
                throw CloudTranscriptionError.unsupportedModel
            }
            if let languageCode {
                guard (cloud.protocolKind == .qwenAudioChat ? (2...3).contains(languageCode.count) : languageCode.count == 2), languageCode.allSatisfy({ $0.isASCII && $0.isLetter }) else {
                    throw ProjectValidationError.invalidSourceLanguage
                }
            }
        }
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectValidationError.emptyModelID
        }
        switch languageMode {
        case .automatic:
            guard languageCode == nil else { throw ProjectValidationError.invalidSourceLanguage }
        case .specified:
            guard let languageCode, !languageCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProjectValidationError.invalidSourceLanguage
            }
        }
    }
}

public struct TranslationSettings: Codable, Equatable, Sendable {
    public static let defaultBatchSize = 30
    public static let defaultSystemPrompt = "Translate the subtitles into the targetLanguage in the user JSON. Preserve meaning, tone and readable subtitle phrasing."

    public struct APIConfiguration: Codable, Equatable, Sendable {
        public let serviceID: UUID?
        public let baseURL: URL
        public let modelID: String
        public let systemPrompt: String
    }

    public enum Engine: Codable, Equatable, Sendable {
        case openAICompatible(APIConfiguration)
        case appleTranslation(sourceLanguage: String)
    }

    public let engine: Engine
    public let targetLanguage: String
    public let batchSize: Int

    public var api: APIConfiguration? {
        if case .openAICompatible(let configuration) = engine { return configuration }
        return nil
    }

    public init(baseURL: URL, modelID: String, targetLanguage: String, serviceID: UUID? = nil,
                batchSize: Int = Self.defaultBatchSize, systemPrompt: String = Self.defaultSystemPrompt) throws {
        engine = .openAICompatible(APIConfiguration(serviceID: serviceID, baseURL: baseURL,
                                                    modelID: modelID, systemPrompt: systemPrompt))
        self.targetLanguage = targetLanguage
        self.batchSize = batchSize
        try validate()
    }

    public init(appleSourceLanguage: String, targetLanguage: String, batchSize: Int = Self.defaultBatchSize) throws {
        engine = .appleTranslation(sourceLanguage: appleSourceLanguage)
        self.targetLanguage = targetLanguage
        self.batchSize = batchSize
        try validate()
    }

    public func validate() throws {
        guard batchSize > 0 else { throw ProjectValidationError.invalidTranslationBatchSize }
        guard !targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectValidationError.invalidTranslationSettings
        }
        switch engine {
        case .appleTranslation(let sourceLanguage):
            guard !sourceLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProjectValidationError.invalidSourceLanguage
            }
        case .openAICompatible(let api):
            guard !api.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProjectValidationError.emptyTranslationSystemPrompt
            }
            guard let parts = URLComponents(url: api.baseURL, resolvingAgainstBaseURL: false),
                  parts.scheme == "https" || parts.scheme == "http", let host = parts.host, !host.isEmpty,
                  parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
                  !api.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProjectValidationError.invalidTranslationSettings
            }
        }
    }
}

public enum ProjectValidationError: Error, LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case invalidMediaIdentity
    case emptyModelID
    case invalidSourceLanguage
    case invalidTranslationSettings
    case invalidTranslationBatchSize
    case emptyTranslationSystemPrompt
    case invalidCue(UUID)
    case invalidTranslation(UUID)
    case sourceRevisionOverflow(UUID)
    case duplicateCue(UUID)
    case overlappingOrUnorderedCue(UUID)
    case cueOutsideMedia(UUID)
    case differentMedia

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): String(localized: "不支持项目格式版本 \(version)，请使用兼容版本的 Voxline。", bundle: voxlineLocalizationBundle)
        case .invalidMediaIdentity: String(localized: "媒体文件信息无效。", bundle: voxlineLocalizationBundle)
        case .emptyModelID: String(localized: "转写模型不能为空。", bundle: voxlineLocalizationBundle)
        case .invalidSourceLanguage: String(localized: "请选择自动识别或明确的原文语言。", bundle: voxlineLocalizationBundle)
        case .invalidTranslationBatchSize: String(localized: "每批字幕数量必须是正整数。", bundle: voxlineLocalizationBundle)
        case .emptyTranslationSystemPrompt: String(localized: "系统提示词不能为空。", bundle: voxlineLocalizationBundle)
        case .invalidTranslationSettings: String(localized: "翻译设置无效。服务地址不能包含账户、密码、查询参数或片段。", bundle: voxlineLocalizationBundle)
        case .invalidCue: String(localized: "字幕包含空白原文、无效时间或无效原文版本。", bundle: voxlineLocalizationBundle)
        case .invalidTranslation: String(localized: "译文内容、原文版本或错误原因无效。", bundle: voxlineLocalizationBundle)
        case .sourceRevisionOverflow: String(localized: "原文版本已达到上限，无法继续修改。", bundle: voxlineLocalizationBundle)
        case .duplicateCue: String(localized: "项目包含重复的字幕 ID。", bundle: voxlineLocalizationBundle)
        case .overlappingOrUnorderedCue: String(localized: "字幕时间重叠或顺序错误，请校正后保存。", bundle: voxlineLocalizationBundle)
        case .cueOutsideMedia: String(localized: "字幕时间超出媒体范围。", bundle: voxlineLocalizationBundle)
        case .differentMedia: String(localized: "媒体文件已更改，请重新关联。", bundle: voxlineLocalizationBundle)
        }
    }
}
