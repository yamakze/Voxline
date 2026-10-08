import CryptoKit
import Foundation

struct ModelFileManifest: Codable, Equatable, Sendable {
    let modelID: String
    let modelRepository: String
    let modelRevision: String
    let modelFiles: [File]
    let tokenizerRepository: String
    let tokenizerRevision: String
    let tokenizerFiles: [File]

    struct File: Codable, Equatable, Sendable {
        let path: String
        let byteCount: Int64
        let digest: String
        let algorithm: Algorithm
        enum Algorithm: String, Codable, Sendable { case sha256, gitSHA1 }
    }

    static func baseline() throws -> Self {
        let url = voxlineLocalizationBundle.url(forResource: "BaselineModel", withExtension: "json")
        guard let url else {
            throw WhisperModelError.missingManifest
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    /// SHA-1 here is the repository's Git blob identity, not a security policy.
    static func verify(_ files: [File], in directory: URL, hashes: Bool) throws {
        for file in files {
            if hashes { try Task.checkCancellation() }
            let url = directory.appendingPathComponent(file.path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, values.fileSize == Int(file.byteCount) else {
                throw WhisperModelError.incompleteFile(file.path)
            }
            if !hashes { continue }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var sha256 = SHA256()
            var gitSHA1 = Insecure.SHA1()
            gitSHA1.update(data: Data("blob \(file.byteCount)\0".utf8))
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                switch file.algorithm {
                case .sha256: sha256.update(data: data)
                case .gitSHA1: gitSHA1.update(data: data)
                }
            }
            let digest: String
            switch file.algorithm {
            case .sha256: digest = sha256.finalize().map { String(format: "%02x", $0) }.joined()
            case .gitSHA1: digest = gitSHA1.finalize().map { String(format: "%02x", $0) }.joined()
            }
            guard digest == file.digest else { throw WhisperModelError.differentFile(file.path) }
        }
    }
}

public enum WhisperModelError: Error, LocalizedError, Equatable {
    case missingManifest, unknownModel, differentVersion, notInstalled
    case incompleteFile(String), differentFile(String)
    case insufficientSpace(required: Int64, available: Int64), unavailableDiskSpace

    public var errorDescription: String? {
        switch self {
        case .missingManifest: String(localized: "应用缺少模型版本清单，请重新构建应用。", bundle: voxlineLocalizationBundle)
        case .unknownModel: String(localized: "当前只支持已验证的 S001 基准型号。", bundle: voxlineLocalizationBundle)
        case .differentVersion: String(localized: "本地模型版本不匹配，请重新下载。", bundle: voxlineLocalizationBundle)
        case .notInstalled: String(localized: "模型尚未完整安装，请先下载。", bundle: voxlineLocalizationBundle)
        case .incompleteFile(let file): String(localized: "模型文件缺失或不完整：\(file)", bundle: voxlineLocalizationBundle)
        case .differentFile(let file): String(localized: "模型文件与固定版本不符：\(file)", bundle: voxlineLocalizationBundle)
        case .insufficientSpace(let required, let available):
            String(localized: "可用空间不足，需要 \(required / 1_000_000) MB，可用 \(available / 1_000_000) MB。", bundle: voxlineLocalizationBundle)
        case .unavailableDiskSpace: String(localized: "无法读取模型目录的可用空间。", bundle: voxlineLocalizationBundle)
        }
    }
}
