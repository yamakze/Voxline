import VoxlineCore

enum ProcessingAvailability {
    static func reason(for task: ProcessingTask) -> String? {
        if task.items.isEmpty { return "请先添加本地音视频。" }
        return nil
    }
}
