import Foundation
import VoxlineCore

public enum SubtitleExportError: LocalizedError, Equatable {
    case emptyCues
    case noValidTranslations
    case writeFailed(String)
    case fileAlreadyExists

    public var errorDescription: String? {
        switch self {
        case .emptyCues: "当前媒体没有字幕，无法导出。"
        case .noValidTranslations: "当前媒体没有有效的译文。请先完成翻译或仅导出原文。"
        case .writeFailed(let reason): "导出失败：\(reason)"
        case .fileAlreadyExists: "目标文件已存在。"
        }
    }
}

public enum SubtitleExporter {
    public static func formatSRTTimestamp(milliseconds: Int64) -> String {
        let totalSeconds = milliseconds / 1000
        let ms = milliseconds % 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, ms)
    }

    public static func generateSRT(cues: [SubtitleCue], kind: SRTOutputKind) throws -> String {
        guard !cues.isEmpty else { throw SubtitleExportError.emptyCues }

        if kind == .translation || kind == .bilingual {
            let validCount = cues.filter(\.hasCurrentTranslation).count
            guard validCount > 0 else { throw SubtitleExportError.noValidTranslations }
        }

        var lines: [String] = []
        var index = 1

        for cue in cues {
            let start = formatSRTTimestamp(milliseconds: cue.startMilliseconds)
            let end = formatSRTTimestamp(milliseconds: cue.endMilliseconds)
            let timeLine = "\(start) --> \(end)"

            let text: String
            switch kind {
            case .source:
                text = cue.sourceText
            case .translation:
                if case .succeeded(let trans, _) = cue.translation, cue.hasCurrentTranslation {
                    text = trans
                } else {
                    continue
                }
            case .bilingual:
                if case .succeeded(let trans, _) = cue.translation, cue.hasCurrentTranslation {
                    text = "\(cue.sourceText)\n\(trans)"
                } else {
                    text = cue.sourceText
                }
            }

            lines.append("\(index)")
            lines.append(timeLine)
            lines.append(text)
            lines.append("")
            index += 1
        }

        return lines.joined(separator: "\n")
    }

    public static func suggestedFileName(mediaTitle: String, kind: SRTOutputKind) -> String {
        let base = (mediaTitle as NSString).deletingPathExtension
        switch kind {
        case .source: return "\(base).en.srt"
        case .translation: return "\(base).zh.srt"
        case .bilingual: return "\(base).bilingual.srt"
        }
    }

    public static func export(cues: [SubtitleCue], kind: SRTOutputKind, to fileURL: URL, allowOverwrite: Bool = false) throws {
        if FileManager.default.fileExists(atPath: fileURL.path) && !allowOverwrite {
            throw SubtitleExportError.fileAlreadyExists
        }

        let srtContent = try generateSRT(cues: cues, kind: kind)
        guard let data = srtContent.data(using: .utf8) else {
            throw SubtitleExportError.writeFailed("无法以 UTF-8 编码字幕内容。")
        }

        try data.write(to: fileURL, options: .atomic)
    }
}
