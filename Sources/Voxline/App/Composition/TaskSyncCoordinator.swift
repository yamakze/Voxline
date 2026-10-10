import VoxlineWorkflow

extension TaskSyncCoordinator {
    @MainActor static let shared: TaskSyncCoordinator = {
        #if os(macOS)
        return TaskSyncCoordinator(library: TaskLibrary.shared)
        #else
        return TaskSyncCoordinator(library: IOSTaskLibrary.shared.storage)
        #endif
    }()
}
