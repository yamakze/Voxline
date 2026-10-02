import Foundation
import Testing
import VoxlineCore
@testable import VoxlineMedia

@Suite("Device-local media associations")
struct MediaAssociationTests {
    @Test func renamedIdenticalFilePreservesProjectAndEdits() throws {
        var project = SubtitleProject()
        let original = try MediaIdentity(fileName: "original.mp4", byteCount: 123,
                                        sha256: String(repeating: "a", count: 64), durationMilliseconds: 5000, audioTrackID: 2)
        try project.associateMedia(original)
        project.cues = [try SubtitleCue(id: UUID(), startMilliseconds: 100, endMilliseconds: 900, sourceText: "Edited")]
        let expected = project
        let renamed = try MediaIdentity(fileName: "renamed.mp4", byteCount: 123,
                                       sha256: original.sha256, durationMilliseconds: 5000, audioTrackID: 2)
        try project.associateMedia(renamed)
        #expect(project == expected)
    }

    @Test(arguments: [true, false])
    func wrongVideoOrAudioTrackCannotReplaceExistingSubtitles(changedContent: Bool) throws {
        var project = SubtitleProject()
        let original = try MediaIdentity(fileName: "original.mp4", byteCount: 123,
                                        sha256: String(repeating: "a", count: 64), durationMilliseconds: 5000, audioTrackID: 2)
        try project.associateMedia(original)
        let expected = project
        let other = try MediaIdentity(fileName: "other.mp4", byteCount: 123,
                                     sha256: String(repeating: changedContent ? "b" : "a", count: 64),
                                     durationMilliseconds: 5000, audioTrackID: changedContent ? 2 : 3)
        #expect(throws: ProjectValidationError.differentMedia) { try project.associateMedia(other) }
        #expect(project == expected)
    }

    @Test func missingAssociationAndCorruptRecordAreDifferentStates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LocalMediaStore(directory: directory)
        let id = UUID()
        let media = try MediaIdentity(fileName: "video.mp4", byteCount: 123, sha256: String(repeating: "a", count: 64),
                                      durationMilliseconds: 5000, audioTrackID: 1)
        #expect(try await store.resolve(projectID: id, identity: media) == nil)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent(id.uuidString).appendingPathExtension("json"))
        await #expect(throws: DecodingError.self) { try await store.resolve(projectID: id, identity: media) }
    }

    @Test func shorterMediaCannotLeaveAPartiallyAssociatedProject() throws {
        var project = SubtitleProject()
        let cue = try SubtitleCue(id: UUID(), startMilliseconds: 100, endMilliseconds: 900, sourceText: "Keep this edit")
        project.cues = [cue]
        let original = project
        let media = try MediaIdentity(fileName: "short.mov", byteCount: 123, sha256: String(repeating: "a", count: 64),
                                      durationMilliseconds: 500, audioTrackID: 1)
        #expect(throws: ProjectValidationError.cueOutsideMedia(cue.id)) { try project.associateMedia(media) }
        #expect(project == original)
    }

    @Test func unsupportedAndBrokenInputsNeverProduceMediaIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inspector = MediaInspector()
        await #expect(throws: MediaAccessError.unsupportedFormat) { try await inspector.inspect(directory.appendingPathComponent("video.mkv")) }
        let empty = directory.appendingPathComponent("empty.mp4")
        try Data().write(to: empty)
        await #expect(throws: MediaAccessError.invalidFile) { try await inspector.inspect(empty) }
        let corrupt = directory.appendingPathComponent("broken.mov")
        try Data("not a movie".utf8).write(to: corrupt)
        await #expect(throws: (any Error).self) { try await inspector.inspect(corrupt) }
    }
}
