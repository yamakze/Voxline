import Foundation

/// An installation receipt records downloaded files without rereading entire model weights.
struct ModelInstallation: Codable, Sendable {
    let modelID: String
    let modelRepository: String
    let modelRevision: String
    let modelFiles: [File]
    let tokenizerRepository: String
    let tokenizerRevision: String
    let tokenizerFiles: [File]

    struct File: Codable, Sendable {
        let path: String
        let byteCount: Int64
    }

    static let tokenizerPaths = ["tokenizer.json", "tokenizer_config.json"]
    static let modelPaths = ["MelSpectrogram", "AudioEncoder", "TextDecoder"].flatMap { component in
        ["coremldata.bin", "model.mil", "weights/weight.bin"].map { "\(component).mlmodelc/\($0)" }
    }

    static func files(in directory: URL, required: [String]) throws -> [File] {
        for path in required {
            let values = try directory.appendingPathComponent(path).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let count = values.fileSize, count > 0 else {
                throw WhisperModelError.incompleteFile(path)
            }
        }
        var files = [File]()
        // Traverse explicitly so directory read errors cannot silently produce a successful receipt.
        func collect(_ folder: URL, prefix: String) throws {
            for url in try FileManager.default.contentsOfDirectory(at: folder,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey], options: .skipsHiddenFiles) {
                try Task.checkCancellation()
                let path = prefix + url.lastPathComponent
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
                if values.isDirectory == true { try collect(url, prefix: path + "/") }
                else if values.isRegularFile == true, let count = values.fileSize {
                    files.append(File(path: path, byteCount: Int64(count)))
                }
            }
        }
        try collect(directory, prefix: "")
        return files.sorted { $0.path < $1.path }
    }

    static func verify(_ files: [File], in directory: URL, required: [String]) throws {
        let paths = Set(files.map(\.path))
        for path in required where !paths.contains(path) { throw WhisperModelError.incompleteFile(path) }
        for file in files {
            try Task.checkCancellation()
            let values = try directory.appendingPathComponent(file.path).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, file.byteCount > 0, values.fileSize == Int(file.byteCount) else {
                throw WhisperModelError.incompleteFile(file.path)
            }
        }
    }
}

public enum WhisperModelError: Error, LocalizedError, Equatable {
    case unknownModel, notInstalled
    case incompleteFile(String)

    public var errorDescription: String? {
        switch self {
        case .unknownModel: String(localized: "找不到所选模型。", bundle: voxlineLocalizationBundle)
        case .notInstalled: String(localized: "模型尚未完整安装，请先下载。", bundle: voxlineLocalizationBundle)
        case .incompleteFile(let file): String(localized: "模型文件缺失或不完整：\(file)", bundle: voxlineLocalizationBundle)
        }
    }
}
