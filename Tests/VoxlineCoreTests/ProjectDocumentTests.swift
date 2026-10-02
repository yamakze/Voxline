import Foundation
import Testing
@testable import VoxlineCore

@Suite("Project document integrity")
struct ProjectDocumentTests {
    @Test func stableIDsAndStaleTranslationSurviveRoundTrip() throws {
        var project = SubtitleProject()
        project.title = "校对项目"
        var cue = try SubtitleCue(id: UUID(), startMilliseconds: 500, endMilliseconds: 1700, sourceText: "Original line")
        cue.translation = .succeeded(text: "原始译文", sourceRevision: cue.sourceRevision)
        try cue.replaceSourceText(with: "Corrected line")
        project.cues = [cue]

        let reopened = try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(project))
        #expect(reopened == project)
        #expect(reopened.cues[0].id == cue.id)
        #expect(reopened.cues[0].sourceRevision == 2)
        #expect(!reopened.cues[0].hasCurrentTranslation)
        #expect(reopened.cues[0].translation == .succeeded(text: "原始译文", sourceRevision: 1))
    }

    @Test func futureVersionIsRejectedBeforeInterpretingUnknownPayload() throws {
        let data = Data(#"{"formatVersion":2,"futurePayload":{"layout":"changed"}}"#.utf8)
        #expect(throws: ProjectValidationError.unsupportedVersion(2)) { try ProjectDocumentCodec.decode(data) }
    }

    @Test func truncatedDocumentCannotBecomeEmptyProject() throws {
        let data = Data(#"{"formatVersion":1,"id":"broken""#.utf8)
        #expect(throws: DecodingError.self) { try ProjectDocumentCodec.decode(data) }
    }

    @Test func duplicateCueIDsCannotBePersisted() throws {
        var project = SubtitleProject()
        let id = UUID()
        project.cues = [
            try SubtitleCue(id: id, startMilliseconds: 0, endMilliseconds: 1000, sourceText: "One"),
            try SubtitleCue(id: id, startMilliseconds: 1000, endMilliseconds: 2000, sourceText: "Two")
        ]
        #expect(throws: ProjectValidationError.duplicateCue(id)) { try ProjectDocumentCodec.encode(project) }
    }

    @Test func invalidDecodedTimelineIsRejected() throws {
        var project = SubtitleProject()
        project.cues = [try SubtitleCue(id: UUID(), startMilliseconds: 0, endMilliseconds: 1000, sourceText: "Line")]
        var payload = try #require(JSONSerialization.jsonObject(with: ProjectDocumentCodec.encode(project)) as? [String: Any])
        var cues = try #require(payload["cues"] as? [[String: Any]])
        cues[0]["startMilliseconds"] = -1
        payload["cues"] = cues
        let data = try JSONSerialization.data(withJSONObject: payload)
        #expect(throws: ProjectValidationError.invalidCue(project.cues[0].id)) { try ProjectDocumentCodec.decode(data) }
    }

    @Test func overlappingCuesCannotBeSilentlySortedOrClipped() throws {
        var project = SubtitleProject()
        let second = try SubtitleCue(id: UUID(), startMilliseconds: 800, endMilliseconds: 2000, sourceText: "Two")
        project.cues = [try SubtitleCue(id: UUID(), startMilliseconds: 0, endMilliseconds: 1000, sourceText: "One"), second]
        #expect(throws: ProjectValidationError.overlappingOrUnorderedCue(second.id)) { try ProjectDocumentCodec.encode(project) }
        #expect(project.cues[1].startMilliseconds == 800)
    }

    @Test(arguments: ["https://user:secret@example.test/v1", "https://example.test/v1?api_key=secret", "https://example.test/v1#secret"])
    func credentialsCannotEnterPortableSettings(endpoint: String) throws {
        let url = try #require(URL(string: endpoint))
        #expect(throws: ProjectValidationError.invalidTranslationSettings) {
            try TranslationSettings(baseURL: url, modelID: "test-model", targetLanguage: "zh-Hans")
        }
    }

    @Test func associatedMediaBoundsProtectTheTimeline() throws {
        var project = SubtitleProject()
        project.media = try MediaIdentity(fileName: "sample.mp4", byteCount: 42, sha256: String(repeating: "a", count: 64), durationMilliseconds: 2000, audioTrackID: 1)
        let cue = try SubtitleCue(id: UUID(), startMilliseconds: 1900, endMilliseconds: 2100, sourceText: "Outside")
        project.cues = [cue]
        #expect(throws: ProjectValidationError.cueOutsideMedia(cue.id)) { try ProjectDocumentCodec.encode(project) }
    }

    @Test func failedTranslationKeepsItsReasonAcrossSave() throws {
        var project = SubtitleProject()
        var cue = try SubtitleCue(id: UUID(), startMilliseconds: 0, endMilliseconds: 1000, sourceText: "Line")
        cue.translation = .failed(reason: "Service rejected the request")
        project.cues = [cue]
        let reopened = try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(project))
        #expect(reopened.cues[0].translation == cue.translation)
        #expect(!reopened.cues[0].hasCurrentTranslation)
    }
}
