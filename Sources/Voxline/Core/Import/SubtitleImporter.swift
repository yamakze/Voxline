import Foundation

public enum SubtitleFileFormat: String, Sendable { case srt, vtt }

public struct SubtitleImportEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let text: String

    public init(id: UUID = UUID(), startMilliseconds: Int64, endMilliseconds: Int64, text: String) {
        self.id = id
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.text = text
    }

    public func cue() throws -> SubtitleCue {
        try SubtitleCue(id: id, startMilliseconds: startMilliseconds, endMilliseconds: endMilliseconds, sourceText: text)
    }
}

public enum ImportedSubtitleOrigin: Codable, Equatable, Sendable {
    case file(name: String)
    case embedded(trackID: Int32, language: String?)
}

public struct SubtitleImportSelection: Sendable {
    public let entries: [SubtitleImportEntry]
    public let origin: ImportedSubtitleOrigin
    public init(entries: [SubtitleImportEntry], origin: ImportedSubtitleOrigin) {
        self.entries = entries; self.origin = origin
    }
}

public enum SubtitleImportError: LocalizedError, Equatable {
    case unsupportedEncoding, invalidRecord(Int), emptyFile, missingSource, replacementRequired

    public var errorDescription: String? {
        switch self {
        case .unsupportedEncoding: String(localized: "无法读取字幕编码，请使用 UTF-8 或 UTF-16。", bundle: voxlineLocalizationBundle)
        case .invalidRecord(let line): String(localized: "第 \(line) 行字幕的时间或内容无效。", bundle: voxlineLocalizationBundle)
        case .emptyFile: String(localized: "文件中没有可导入的字幕。", bundle: voxlineLocalizationBundle)
        case .missingSource: String(localized: "请先导入原文字幕。", bundle: voxlineLocalizationBundle)
        case .replacementRequired: String(localized: "当前已有字幕，请确认替换。", bundle: voxlineLocalizationBundle)
        }
    }
}

public enum SubtitleImporter {
    public static func parse(_ data: Data, format: SubtitleFileFormat) throws -> [SubtitleImportEntry] {
        let text: String?
        if data.starts(with: [0xff, 0xfe]) { text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        else if data.starts(with: [0xfe, 0xff]) { text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        else { text = String(data: data, encoding: .utf8) }
        guard let text else { throw SubtitleImportError.unsupportedEncoding }
        return try parse(text, format: format)
    }

    public static func parse(_ text: String, format: SubtitleFileFormat) throws -> [SubtitleImportEntry] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}")).components(separatedBy: "\n")
        if format == .vtt, !(lines[0] == "WEBVTT" || lines[0].hasPrefix("WEBVTT ") || lines[0].hasPrefix("WEBVTT\t")) {
            throw SubtitleImportError.invalidRecord(1)
        }
        let timing = try NSRegularExpression(pattern: #"^\s*((?:\d+:)?\d{2}:\d{2}[,.]\d{1,3})\s*-->\s*((?:\d+:)?\d{2}:\d{2}[,.]\d{1,3})(?:\s+.*)?$"#)
        var blocks: [(line: Int, lines: [String])] = []
        var block: [String] = []
        var firstLine = 1
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !block.isEmpty { blocks.append((firstLine, block)); block = [] }
            } else {
                if block.isEmpty { firstLine = index + 1 }
                block.append(line)
            }
        }
        if !block.isEmpty { blocks.append((firstLine, block)) }
        var entries: [SubtitleImportEntry] = []
        for block in blocks {
            let first = block.lines[0]
            if format == .vtt, first.hasPrefix("WEBVTT") || first == "NOTE" || first.hasPrefix("NOTE ") || first.hasPrefix("NOTE\t") || first == "STYLE" || first == "REGION" { continue }
            let timeIndex = first.contains("-->") ? 0 : 1
            guard block.lines.indices.contains(timeIndex) else { throw SubtitleImportError.invalidRecord(block.line) }
            let line = block.lines[timeIndex]
            guard let match = timing.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let startRange = Range(match.range(at: 1), in: line), let endRange = Range(match.range(at: 2), in: line),
                  let start = milliseconds(String(line[startRange])), let end = milliseconds(String(line[endRange])), end > start else {
                throw SubtitleImportError.invalidRecord(block.line + timeIndex)
            }
            let body = plainText(block.lines.dropFirst(timeIndex + 1).joined(separator: "\n"))
            guard !body.isEmpty else { throw SubtitleImportError.invalidRecord(block.line + timeIndex + 1) }
            entries.append(.init(startMilliseconds: start, endMilliseconds: end, text: body))
        }
        guard !entries.isEmpty else { throw SubtitleImportError.emptyFile }
        // File numbering and ordering are presentation details; retain equal-start ordering.
        return entries.sorted { $0.startMilliseconds < $1.startMilliseconds }
    }

    private static func milliseconds(_ text: String) -> Int64? {
        let components = text.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard components.count == 2 || components.count == 3 else { return nil }
        let seconds = components.last!.split(separator: ".")
        guard seconds.count == 2, let second = Int64(seconds[0]), second < 60,
              let minute = Int64(components[components.count - 2]), minute < 60,
              let fraction = Int64(seconds[1].padding(toLength: 3, withPad: "0", startingAt: 0)) else { return nil }
        let hour = components.count == 3 ? Int64(components[0]) : 0
        guard let hour, hour >= 0, hour <= (Int64.max - 3_600_000) / 3_600_000 else { return nil }
        return hour * 3_600_000 + minute * 60_000 + second * 1000 + fraction
    }

    // Fixed source-code patterns: compilation failure is a programming error, not invalid subtitle data.
    private static let presentationTags = try! NSRegularExpression(
        pattern: #"</?(?:b|i|u|font|c|v|lang|ruby|rt)(?:[.\s][^>]*)?>|<\d{2}:\d{2}(?::\d{2})?\.\d{3}>"#, options: .caseInsensitive)
    private static let characterReferences = try! NSRegularExpression(
        pattern: #"&(#(?:[xX][0-9a-fA-F]+|[0-9]+)|lt|gt|quot|apos|nbsp|amp);"#)
    private static let namedCharacters = ["lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "amp": "&"]

    public static func plainText(_ text: String) -> String {
        let unstyled = presentationTags.stringByReplacingMatches(in: text,
            range: NSRange(text.startIndex..., in: text), withTemplate: "") as NSString
        var result = ""
        var cursor = 0
        for match in characterReferences.matches(in: unstyled as String, range: NSRange(location: 0, length: unstyled.length)) {
            result += unstyled.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let reference = unstyled.substring(with: match.range(at: 1))
            if reference.hasPrefix("#") {
                let number = reference.dropFirst()
                let value = number.hasPrefix("x") || number.hasPrefix("X")
                    ? UInt32(number.dropFirst(), radix: 16) : UInt32(number)
                if let value, let scalar = UnicodeScalar(value) { result += String(scalar) }
                else { result += unstyled.substring(with: match.range) }
            } else { result += namedCharacters[reference] ?? unstyled.substring(with: match.range) }
            cursor = NSMaxRange(match.range)
        }
        result += unstyled.substring(from: cursor)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
