import Foundation
import Testing
@testable import VoxlineCore

@Suite("Strict SRT export")
struct SubtitleExporterTests {
    private func cue(start: Int64 = 3_600_001, end: Int64 = 3_602_999) throws -> SubtitleCue {
        var cue = try SubtitleCue(id: UUID(), startMilliseconds: start, endMilliseconds: end,
                                  sourceText: "Hello.\r\n\r\nWorld!")
        cue.translation = .succeeded(text: "你好。\n\n世界！", sourceRevision: 1)
        return cue
    }

    @Test func threeKindsKeepRecordsTimesAndBilingualOrder() throws {
        let cues = try [cue(), cue(start: 3_603_000, end: 3_604_000)]
        let source = try SubtitleExporter.generateSRT(cues: cues, kind: .source)
        #expect(source == "1\n01:00:00,001 --> 01:00:02,999\nHello.\nWorld!\n\n2\n01:00:03,000 --> 01:00:04,000\nHello.\nWorld!\n")
        let translated = try SubtitleExporter.generateSRT(cues: cues, kind: .translation)
        #expect(translated.contains("你好。\n世界！\n\n2\n"))
        #expect(!translated.contains("Hello"))
        let bilingual = try SubtitleExporter.generateSRT(cues: cues, kind: .bilingual)
        #expect(bilingual.contains("Hello.\nWorld!\n你好。\n世界！\n\n2\n"))
        #expect(!bilingual.contains("\r"))
        #expect(SubtitleExporter.formatSRTTimestamp(milliseconds: 3_600_000_001) == "1000:00:00,001")
        #expect(SubtitleExporter.suggestedFileName(mediaTitle: "中文.audio.wav", kind: .source) == "中文.audio.source.srt")
    }

    @Test(arguments: [SRTOutputKind.translation, .bilingual])
    func incompleteOrOutdatedTranslationRejectsWholeExport(kind: SRTOutputKind) throws {
        let valid = try cue(start: 0, end: 1000)
        var missing = try cue(start: 1000, end: 2000)
        missing.translation = .pending
        #expect(throws: SubtitleExportError.incompleteTranslations(1)) {
            try SubtitleExporter.generateSRT(cues: [valid, missing], kind: kind)
        }
        missing.translation = .failed(reason: "Service unavailable")
        #expect(throws: SubtitleExportError.incompleteTranslations(1)) {
            try SubtitleExporter.generateSRT(cues: [valid, missing], kind: kind)
        }
        missing.translation = .succeeded(text: "人工译文", sourceRevision: 1)
        try missing.replaceSourceText(with: "Edited source")
        #expect(throws: SubtitleExportError.incompleteTranslations(1)) {
            try SubtitleExporter.generateSRT(cues: [valid, missing], kind: kind)
        }
        #expect(try SubtitleExporter.generateSRT(cues: [valid, missing], kind: .source).contains("Edited source"))
    }

    @Test func invalidTimelineOrMediaBoundaryCannotBeSerialized() throws {
        #expect(throws: SubtitleExportError.emptyCues) { try SubtitleExporter.generateSRT(cues: [], kind: .source) }
        var invalid = try cue(start: 0, end: 1000)
        invalid.startMilliseconds = -1
        #expect(throws: (any Error).self) { try SubtitleExporter.generateSRT(cues: [invalid], kind: .source) }
        let first = try cue(start: 0, end: 1000), overlapping = try cue(start: 500, end: 1500)
        #expect(throws: (any Error).self) { try SubtitleExporter.generateSRT(cues: [first, overlapping], kind: .bilingual) }
        #expect(throws: (any Error).self) { try SubtitleExporter.generateSRT(cues: [first, first], kind: .source) }
        let media = try MediaIdentity(fileName: "clip.mp4", byteCount: 1, sha256: String(repeating: "a", count: 64), durationMilliseconds: 500, audioTrackID: 1)
        #expect(throws: (any Error).self) { try SubtitleExporter.generateSRT(cues: [first], kind: .source, media: media) }
    }

    @Test func atomicUTF8WriteRequiresOverwriteChoiceAndPreservesFileOnValidationFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("中文.bilingual.srt")
        let original = Data("existing subtitles".utf8)
        try original.write(to: url)
        let valid = try cue()
        #expect(throws: SubtitleExportError.fileAlreadyExists) {
            try SubtitleExporter.export(cues: [valid], kind: .bilingual, to: url)
        }
        #expect(try Data(contentsOf: url) == original)
        var invalid = valid
        invalid.translation = .pending
        #expect(throws: SubtitleExportError.incompleteTranslations(1)) {
            try SubtitleExporter.export(cues: [invalid], kind: .translation, to: url, allowOverwrite: true)
        }
        #expect(try Data(contentsOf: url) == original)
        try SubtitleExporter.export(cues: [valid], kind: .bilingual, to: url, allowOverwrite: true)
        #expect(try Data(contentsOf: url) == Data(SubtitleExporter.generateSRT(cues: [valid], kind: .bilingual).utf8))
        let blocked = directory.appendingPathComponent("blocked")
        try Data("occupied".utf8).write(to: blocked)
        do {
            try SubtitleExporter.export(cues: [valid], kind: .source, to: blocked.appendingPathComponent("file.srt"))
            Issue.record("Expected explicit write failure")
        } catch SubtitleExportError.writeFailed(let reason) { #expect(!reason.isEmpty) }
    }

    @Test(arguments: ["", ".srt", "../clip.srt", "folder/clip.srt", "folder\\clip.srt", "clip.txt", "clip\0.srt"])
    func invalidFileNameCannotEscapeChosenDirectory(name: String) {
        #expect(throws: SubtitleExportError.invalidFileName) { try SubtitleExporter.validateFileName(name) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXLINE_SRT_TASK"] != nil))
    func realTaskExportsAllThreeKindsWithoutMutatingTask() throws {
        let path = try #require(ProcessInfo.processInfo.environment["VOXLINE_SRT_TASK"])
        let url = URL(fileURLWithPath: path)
        let original = try Data(contentsOf: url)
        let task = try TaskDocumentCodec.decode(original)
        let item = try #require(task.items.first)
        let directory = url.deletingLastPathComponent().appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for kind in [SRTOutputKind.source, .translation, .bilingual] {
            let output = directory.appendingPathComponent(SubtitleExporter.suggestedFileName(mediaTitle: try #require(item.media).fileName, kind: kind))
            try SubtitleExporter.export(cues: item.cues, kind: kind, to: output, media: item.media, allowOverwrite: true)
            let content = try String(contentsOf: output, encoding: .utf8)
            #expect(content.components(separatedBy: "\n\n").count == item.cues.count)
            #expect(content.contains("6\n"))
            #expect(!content.contains("\r"))
        }
        #expect(try Data(contentsOf: url) == original)
    }
}
