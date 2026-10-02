import Foundation
import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore

extension UTType {
    static let voxlineProject = UTType(exportedAs: "dev.voxline.project", conformingTo: .json)
}

struct VoxlineDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.voxlineProject] }
    var task: ProcessingTask

    init() { task = ProcessingTask() }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        task = try TaskDocumentCodec.decode(data)
        task.interruptRunningItems()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try TaskDocumentCodec.encode(task))
    }
}
