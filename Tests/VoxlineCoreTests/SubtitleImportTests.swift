import Foundation
import Testing
@testable import VoxlineCore

@Suite("Imported subtitles and overlapping timelines")
struct SubtitleImportTests {
    @Test func srtAndVttKeepTextTimingOverlapAndIgnorePresentationMetadata() throws {
        let srt = "\u{feff}9\r\n00:00:01,000 --> 00:00:03,000\r\n<b>Hello</b> &amp; world\r\nSecond line\r\n\r\n42\r\n00:00:02,000 --> 00:00:04,000\r\n你好\r\n"
        let parsed = try SubtitleImporter.parse(Data(srt.utf8), format: .srt)
        #expect(parsed.map(\.text) == ["Hello & world\nSecond line", "你好"])
        #expect(parsed.map(\.startMilliseconds) == [1000, 2000])
        #expect(parsed.map(\.endMilliseconds) == [3000, 4000])
        let utf16 = Data([0xff, 0xfe]) + (try #require(srt.data(using: .utf16LittleEndian)))
        #expect(try SubtitleImporter.parse(utf16, format: .srt).map(\.text) == parsed.map(\.text))
        let vtt = "WEBVTT\n\nNOTE diagnostic\nnot dialogue\n\nSTYLE\n::cue { color: red; }\n\nintro\n00:01.000 --> 00:03.000 align:start\n<v Speaker>Hello &amp; world</v>\nSecond line\n\n42\n00:00:02.000 --> 00:00:04.000\n你好\n"
        let web = try SubtitleImporter.parse(vtt, format: .vtt)
        #expect(web.map(\.text) == parsed.map(\.text))
        #expect(web.map(\.startMilliseconds) == parsed.map(\.startMilliseconds))
        #expect(web.map(\.endMilliseconds) == parsed.map(\.endMilliseconds))
        #expect(throws: (any Error).self) { try SubtitleImporter.parse(srt + "\n8\n00:00:06,000 --> 00:00:05,000\nbad", format: .srt) }
    }

    @Test func importsPersistWithoutRecognitionAndKeepUnmatchedTranslationForManualReview() throws {
        let media = try MediaIdentity(fileName: "clip.mp4", byteCount: 123, fingerprint: String(repeating: "a", count: 64), durationMilliseconds: 10_000, audioTrackID: 1)
        let item = TaskMediaItem(title: "clip", kind: .video, source: .localFile(fileName: media.fileName), media: media)
        let translation = try TranslationSettings(appleSourceLanguage: "en", targetLanguage: "zh-Hans")
        var task = ProcessingTask(items: [item], parameters: .init(transcription: .whisperKitBaseline, translation: translation))
        let entries = try SubtitleImporter.parse("1\n00:00:01,000 --> 00:00:03,000\nOne\n\n2\n00:00:02,000 --> 00:00:04,000\nTwo", format: .srt)
        try task.importOriginalSubtitles(mediaID: item.id, entries: entries, origin: .file(name: "clip.srt"), comparedTo: item)
        #expect(task.items[0].checkpoint?.chunks.isEmpty == true)
        #expect(task.items[0].hasSourceSubtitles && !task.items[0].hasCompletedTranscription)
        #expect(task.items[0].canResumeProcessing)
        let translations = [SubtitleImportEntry(startMilliseconds: 1010, endMilliseconds: 2990, text: "一"),
                            SubtitleImportEntry(startMilliseconds: 8000, endMilliseconds: 9000, text: "未匹配")]
        let assignments = SubtitleTranslationImport.assignments(entries: translations, cues: task.items[0].cues)
        #expect(assignments[0].cueID == task.items[0].cues[0].id && assignments[1].cueID == nil)
        try task.items[0].importTranslations(assignments, comparedTo: task.items[0].cues)
        let reopened = try TaskDocumentCodec.decode(TaskDocumentCodec.encode(task))
        #expect(reopened.items[0].unmatchedTranslationEntries == [translations[1]])
        #expect(reopened.items[0].cues[0].translation == .succeeded(text: "一", sourceRevision: 1))
        #expect(reopened.items[0].cues[1].translation == .pending)
        let before = task
        #expect(throws: SubtitleImportError.replacementRequired) {
            try task.importOriginalSubtitles(mediaID: item.id, entries: entries, origin: .file(name: "replacement.srt"), comparedTo: task.items[0])
        }
        #expect(task == before)
        let duplicateTarget = SubtitleTranslationImport.assignments(entries: [translations[0], translations[0]], cues: task.items[0].cues)
        #expect(duplicateTarget.allSatisfy { $0.cueID == nil })
    }

    @Test func displayIntervalsPreserveLongOverlapsAndExactBoundariesWhileSrtKeepsOriginalTimes() throws {
        let cues = try [SubtitleCue(id: UUID(), startMilliseconds: 0, endMilliseconds: 5000, sourceText: "Long"),
                        SubtitleCue(id: UUID(), startMilliseconds: 1000, endMilliseconds: 2000, sourceText: "Short"),
                        SubtitleCue(id: UUID(), startMilliseconds: 1000, endMilliseconds: 3000, sourceText: "Same start"),
                        SubtitleCue(id: UUID(), startMilliseconds: 6000, endMilliseconds: 7000, sourceText: "After gap")]
        let timeline = SubtitleTimeline(cues: cues)
        #expect(timeline.interval(atMilliseconds: 1500)?.cueIndices == [0, 1, 2])
        #expect(timeline.interval(atMilliseconds: 2000)?.cueIndices == [0, 2])
        #expect(timeline.interval(atMilliseconds: 4000)?.cueIndices == [0])
        #expect(timeline.interval(atMilliseconds: 5000) == nil)
        #expect(timeline.interval(atMilliseconds: 6000)?.cueIndices == [3])
        let output = try SubtitleExporter.generateSRT(cues: cues, kind: .source)
        #expect(output.contains("00:00:00,000 --> 00:00:05,000\nLong"))
        #expect(output.contains("00:00:01,000 --> 00:00:02,000\nShort"))
        #expect(cues[0].endMilliseconds == 5000)
    }
}
