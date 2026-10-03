import VoxlineCore

enum ProcessingAvailability {
    static let translationUnavailableReason = "翻译接口尚未接通。新建关闭翻译的任务可生成原文字幕。"

    static func reason(for task: ProcessingTask) -> String? {
        if task.parameters.translation != nil {
            return translationUnavailableReason
        }
        if task.items.isEmpty { return "请先添加本地音视频。" }
        return nil
    }
}
