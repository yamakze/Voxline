import Foundation

public enum TaskDocumentCodec {
    public static func decode(_ data: Data) throws -> ProcessingTask {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let task = try decoder.decode(ProcessingTask.self, from: data)
        try task.validate()
        return task
    }

    public static func encode(_ task: ProcessingTask) throws -> Data {
        try task.validate()
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(task)
    }
}
