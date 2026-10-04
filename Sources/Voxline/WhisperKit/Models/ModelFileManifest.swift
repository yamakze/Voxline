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
        #if SWIFT_PACKAGE
        let url = Bundle.main.bundleURL.pathExtension == "app"
            ? Bundle.main.url(forResource: "BaselineModel", withExtension: "json")
            : Bundle.module.url(forResource: "BaselineModel", withExtension: "json")
        #else
        let url = Bundle(for: ModelResourceBundle.self).url(forResource: "BaselineModel", withExtension: "json")
        #endif
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
    case missingManifest, unknownModel, differentVersion, notInstalled, loadedModel
    case incompleteFile(String), differentFile(String)
    case insufficientSpace(required: Int64, available: Int64), unavailableDiskSpace

    public var errorDescription: String? {
        switch self {
        case .missingManifest: "应用缺少模型版本清单，请重新构建应用。"
        case .unknownModel: "当前只支持已验证的 S001 基准型号。"
        case .differentVersion: "本地模型版本不匹配，请重新下载。"
        case .notInstalled: "模型尚未完整安装，请先下载。"
        case .loadedModel: "模型已加载，请先卸载再删除或重新下载。"
        case .incompleteFile(let file): "模型文件缺失或不完整：\(file)"
        case .differentFile(let file): "模型文件与固定版本不符：\(file)"
        case .insufficientSpace(let required, let available):
            "可用空间不足，需要 \(required / 1_000_000) MB，可用 \(available / 1_000_000) MB。"
        case .unavailableDiskSpace: "无法读取模型目录的可用空间。"
        }
    }
}

#if !SWIFT_PACKAGE
private final class ModelResourceBundle: NSObject {}
#endif
