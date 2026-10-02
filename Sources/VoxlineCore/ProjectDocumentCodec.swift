import Foundation

public enum ProjectDocumentCodec {
    public static func decode(_ data: Data) throws -> SubtitleProject {
        struct Header: Decodable { let formatVersion: Int }
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: data)
        guard header.formatVersion == SubtitleProject.currentFormatVersion else {
            throw ProjectValidationError.unsupportedVersion(header.formatVersion)
        }
        let project = try decoder.decode(SubtitleProject.self, from: data)
        try project.validate()
        return project
    }

    public static func encode(_ project: SubtitleProject) throws -> Data {
        try project.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(project)
    }
}
