import Foundation

public struct SubtitleProject: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    public let formatVersion: Int
    public let id: UUID
    public var title: String
    public var media: MediaIdentity?
    public var transcription: TranscriptionSettings
    public var translation: TranslationSettings?
    public var cues: [SubtitleCue]

    public init() {
        formatVersion = Self.currentFormatVersion
        id = UUID()
        title = "未命名项目"
        media = nil
        transcription = .whisperKitBaseline
        translation = nil
        cues = []
    }

    public func validate() throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw ProjectValidationError.unsupportedVersion(formatVersion)
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectValidationError.emptyTitle
        }
        try media?.validate()
        try transcription.validate()
        try translation?.validate()
        try SubtitleCue.validateTimeline(cues, within: media)
    }

    public mutating func associateMedia(_ candidate: MediaIdentity) throws {
        try candidate.validate()
        if let media, !media.matchesContent(of: candidate) {
            throw ProjectValidationError.differentMedia
        }
        var updated = self
        if updated.media == nil { updated.media = candidate }
        try updated.validate()
        self = updated
    }
}

public struct MediaIdentity: Codable, Equatable, Sendable {
    public let fileName: String
    public let byteCount: Int64
    public let sha256: String
    public let durationMilliseconds: Int64
    public let audioTrackID: Int32

    public init(fileName: String, byteCount: Int64, sha256: String, durationMilliseconds: Int64, audioTrackID: Int32) throws {
        self.fileName = fileName
        self.byteCount = byteCount
        self.sha256 = sha256
        self.durationMilliseconds = durationMilliseconds
        self.audioTrackID = audioTrackID
        try validate()
    }

    public func validate() throws {
        guard !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !fileName.contains("/"), !fileName.contains("\\"), byteCount > 0, durationMilliseconds > 0,
              audioTrackID != 0, sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ProjectValidationError.invalidMediaIdentity
        }
    }

    public func matchesContent(of other: MediaIdentity) -> Bool {
        byteCount == other.byteCount && sha256 == other.sha256 &&
        durationMilliseconds == other.durationMilliseconds && audioTrackID == other.audioTrackID
    }
}

public struct TranscriptionSettings: Codable, Equatable, Sendable {
    public enum Provider: String, Codable, Sendable { case whisperKit }
    public enum LanguageMode: String, Codable, Sendable { case automatic, specified }
    public let provider: Provider
    public let modelID: String
    public let languageMode: LanguageMode
    public let languageCode: String?

    public init(provider: Provider = .whisperKit, modelID: String,
                languageMode: LanguageMode = .automatic, languageCode: String? = nil) {
        self.provider = provider
        self.modelID = modelID
        self.languageMode = languageMode
        self.languageCode = languageCode
    }

    public static let whisperKitBaseline = TranscriptionSettings(
        provider: .whisperKit, modelID: "openai_whisper-large-v3-v20240930_626MB", languageMode: .automatic)

    public func validate() throws {
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
    public let serviceID: UUID?
    public let baseURL: URL
    public let modelID: String
    public let targetLanguage: String
    public let batchSize: Int
    public let systemPrompt: String

    public init(baseURL: URL, modelID: String, targetLanguage: String, serviceID: UUID? = nil,
                batchSize: Int = Self.defaultBatchSize, systemPrompt: String = Self.defaultSystemPrompt) throws {
        self.serviceID = serviceID
        self.baseURL = baseURL
        self.modelID = modelID
        self.targetLanguage = targetLanguage
        self.batchSize = batchSize
        self.systemPrompt = systemPrompt
        try validate()
    }

    private enum CodingKeys: String, CodingKey { case serviceID, baseURL, modelID, targetLanguage, batchSize, systemPrompt }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(baseURL: values.decode(URL.self, forKey: .baseURL),
                      modelID: values.decode(String.self, forKey: .modelID),
                      targetLanguage: values.decode(String.self, forKey: .targetLanguage),
                      serviceID: values.decodeIfPresent(UUID.self, forKey: .serviceID),
                      batchSize: values.contains(.batchSize) ? values.decode(Int.self, forKey: .batchSize) : Self.defaultBatchSize,
                      systemPrompt: values.contains(.systemPrompt) ? values.decode(String.self, forKey: .systemPrompt) : Self.defaultSystemPrompt)
    }

    public func validate() throws {
        guard batchSize > 0 else { throw ProjectValidationError.invalidTranslationBatchSize }
        guard !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectValidationError.emptyTranslationSystemPrompt
        }
        guard let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              parts.scheme == "https" || parts.scheme == "http", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectValidationError.invalidTranslationSettings
        }
    }
}

public enum ProjectValidationError: Error, LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case emptyTitle
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
        case .unsupportedVersion(let version): "不支持项目格式版本 \(version)，请使用兼容版本的 Voxline。"
        case .emptyTitle: "项目名称不能为空。"
        case .invalidMediaIdentity: "媒体身份无效，请检查文件信息、哈希、时长和所选音轨。"
        case .emptyModelID: "转写模型不能为空。"
        case .invalidSourceLanguage: "请选择自动识别或明确的原文语言。"
        case .invalidTranslationBatchSize: "每批字幕数量必须是正整数。"
        case .emptyTranslationSystemPrompt: "系统提示词不能为空。"
        case .invalidTranslationSettings: "翻译设置无效。服务地址不能包含账户、密码、查询参数或片段。"
        case .invalidCue: "字幕包含空白原文、无效时间或无效原文版本。"
        case .invalidTranslation: "译文内容、原文版本或错误原因无效。"
        case .sourceRevisionOverflow: "原文版本已达到上限，无法继续修改。"
        case .duplicateCue: "项目包含重复的字幕 ID。"
        case .overlappingOrUnorderedCue: "字幕时间重叠或顺序错误，请校正后保存。"
        case .cueOutsideMedia: "字幕时间超出媒体范围。"
        case .differentMedia: "媒体内容或音轨与当前条目不一致，请选择原媒体；其他媒体需添加新条目。"
        }
    }
}
