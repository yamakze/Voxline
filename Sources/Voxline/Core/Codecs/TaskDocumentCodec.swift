import Foundation

public enum TaskDocumentCodec {
    public static func decode(_ data: Data) throws -> ProcessingTask {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        var task = try decoder.decode(ProcessingTask.self, from: data)
        try task.validate()
        removeCompletedDiagnostics(from: &task)
        return task
    }

    public static func encode(_ task: ProcessingTask) throws -> Data {
        try task.validate()
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        encoder.outputFormatting = [.sortedKeys]
        var document = task
        removeCompletedDiagnostics(from: &document)
        return try encoder.encode(document)
    }

    private static func removeCompletedDiagnostics(from task: inout ProcessingTask) {
        for itemIndex in task.items.indices {
            guard var record = task.items[itemIndex].checkpoint else { continue }
            for index in record.chunks.indices {
                if case .completed(let result) = record.chunks[index].state,
                   !result.evidence.windows.isEmpty || result.evidence.cloudResult != nil {
                    record.chunks[index].state = .completed(result.checkpointSnapshot)
                }
            }
            task.items[itemIndex].checkpoint = record
        }
    }
}
