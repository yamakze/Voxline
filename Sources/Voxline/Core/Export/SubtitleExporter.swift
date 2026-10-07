import Foundation

public enum SubtitleExportError: LocalizedError, Equatable {
    case emptyCues
    case incompleteTranslations(Int)
    case invalidFileName
    case writeFailed(String)
    case fileAlreadyExists

    public var errorDescription: String? {
        switch self {
        case .emptyCues: "当前媒体没有字幕，无法导出。"
        case .incompleteTranslations(let count): "有 \(count) 条字幕缺少有效译文。请完成翻译或校对后导出，或选择原文 SRT。"
        case .invalidFileName: "请输入不含路径的 .srt 文件名。"
        case .writeFailed(let reason): "导出失败：\(reason)"
        case .fileAlreadyExists: "目标文件已存在。"
        }
    }
}

public enum SubtitleExporter {
    public static func formatSRTTimestamp(milliseconds: Int64) -> String {
        let totalSeconds = milliseconds / 1000
        return String(format: "%02lld:%02lld:%02lld,%03lld", totalSeconds / 3600,
                      (totalSeconds % 3600) / 60, totalSeconds % 60, milliseconds % 1000)
    }

    public static func generateSRT(cues: [SubtitleCue], kind: SRTOutputKind, media: MediaIdentity? = nil) throws -> String {
        guard !cues.isEmpty else { throw SubtitleExportError.emptyCues }
        try SubtitleCue.validateTimeline(cues, within: media)
        if kind != .source {
            let missingCount = cues.filter { !$0.hasCurrentTranslation }.count
            guard missingCount == 0 else { throw SubtitleExportError.incompleteTranslations(missingCount) }
        }

        let records = try cues.enumerated().map { index, cue in
            let text = try subtitleText(for: cue, kind: kind)
            return "\(index + 1)\n\(formatSRTTimestamp(milliseconds: cue.startMilliseconds)) --> \(formatSRTTimestamp(milliseconds: cue.endMilliseconds))\n\(text)\n"
        }
        return records.joined(separator: "\n")
    }

    /// One text projection serves standalone SRT and embedded subtitle samples.
    public static func subtitleText(for cue: SubtitleCue, kind: SRTOutputKind) throws -> String {
        if kind != .source, !cue.hasCurrentTranslation { throw SubtitleExportError.incompleteTranslations(1) }
        func bodyLines(_ text: String) -> String {
            text.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
        }
        var text = kind == .translation ? "" : bodyLines(cue.sourceText)
        if kind != .source, case .succeeded(let translation, _) = cue.translation {
            if kind == .bilingual { text += "\n" }
            text += bodyLines(translation)
        }
        return text
    }

    public static func suggestedFileName(mediaTitle: String, kind: SRTOutputKind) -> String {
        let base = (mediaTitle as NSString).deletingPathExtension
        switch kind {
        case .source: return "\(base).source.srt"
        case .translation: return "\(base).translation.srt"
        case .bilingual: return "\(base).bilingual.srt"
        }
    }

    public static func validateFileName(_ name: String) throws {
        guard !name.contains("/"), !name.contains("\\"), !name.contains("\0"),
              (name as NSString).pathExtension.lowercased() == "srt",
              !(name as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SubtitleExportError.invalidFileName
        }
    }

    public static func export(cues: [SubtitleCue], kind: SRTOutputKind, to fileURL: URL,
                              media: MediaIdentity? = nil, allowOverwrite: Bool = false) throws {
        try validateFileName(fileURL.lastPathComponent)
        let content = try generateSRT(cues: cues, kind: kind, media: media)
        if FileManager.default.fileExists(atPath: fileURL.path), !allowOverwrite {
            throw SubtitleExportError.fileAlreadyExists
        }
        do { try Data(content.utf8).write(to: fileURL, options: .atomic) }
        catch { throw SubtitleExportError.writeFailed(error.localizedDescription) }
    }
}
