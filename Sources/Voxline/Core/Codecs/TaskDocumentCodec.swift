import Foundation

public enum TaskDocumentCodec {
    public static func decode(_ data: Data) throws -> ProcessingTask {
        struct Header: Decodable { let formatVersion: Int }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let header = try decoder.decode(Header.self, from: data)
        switch header.formatVersion {
        case SubtitleProject.currentFormatVersion:
            let project = try ProjectDocumentCodec.decode(data)
            let parameters = TaskParameters(transcription: project.transcription, translation: project.translation)
            // Reuse the former project ID as the media ID so its local bookmark still resolves.
            let items: [TaskMediaItem]
            if project.media != nil || !project.cues.isEmpty {
                items = [TaskMediaItem(id: project.id, title: project.title, kind: .video,
                                       source: project.media.map { .localFile(fileName: $0.fileName) } ?? .unassociated,
                                       media: project.media, status: .needsReview, cues: project.cues)]
            } else { items = [] }
            let task = ProcessingTask(id: project.id, title: project.title, items: items, parameters: parameters)
            try task.validate()
            return task
        case 2, 3, 4, 5, ProcessingTask.currentFormatVersion:
            let task = try decoder.decode(ProcessingTask.self, from: data)
            try task.validate()
            return task
        default: throw ProjectValidationError.unsupportedVersion(header.formatVersion)
        }
    }

    public static func encode(_ task: ProcessingTask) throws -> Data {
        try task.validate()
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(task)
    }
}
