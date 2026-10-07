import VoxlineWorkflow

extension TaskSyncSettings {
    @MainActor static let shared: TaskSyncSettings = {
        #if os(macOS)
        return TaskSyncSettings(library: TaskLibrary.shared)
        #else
        return TaskSyncSettings(library: IOSTaskLibrary.shared.storage)
        #endif
    }()
}
