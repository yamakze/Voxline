import Foundation
import Testing
@testable import VoxlineApp

@Suite("Temporary export ownership")
struct TemporaryExportFileTests {
    @Test(arguments: ["../outside.mp4", "folder/movie.mp4", "/tmp/movie.mp4", "..\\outside.mp4", "movie\0.mp4", "", "  ", ".", ".."])
    func rejectsPathsBeforeCreatingAnExport(_ name: String) {
        #expect(throws: CocoaError(.fileWriteInvalidFileName)) {
            _ = try TemporaryExportFile(fileName: name)
        }
    }

    @Test func independentExportsRetainTheirFilesUntilTheLastOwnerReleasesThem() throws {
        var first: TemporaryExportFile? = try TemporaryExportFile(fileName: "字幕.mp4")
        let directory = try #require(first?.directory)
        let url = try #require(first?.url)
        try Data("first".utf8).write(to: url)
        let second = try TemporaryExportFile(fileName: "字幕.mp4")
        try Data("second".utf8).write(to: second.url)
        #expect(directory != second.directory)
        #expect(url.deletingLastPathComponent() == directory)
        var sharing = first
        first = nil
        #expect(try Data(contentsOf: #require(sharing).url) == Data("first".utf8))
        sharing = nil
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(try Data(contentsOf: second.url) == Data("second".utf8))
    }
}
