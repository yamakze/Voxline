#if os(macOS)
import AppKit
import Combine
import Sparkle
import VoxlineWorkflow

@MainActor
final class MacUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = MacUpdater()
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var isConfigured = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var errorMessage: String?
    private var controller: SPUStandardUpdaterController!
    private var deferredInstallation: Task<Void, Never>?

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloadsUpdates)
    }

    func start() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != nil else {
            isConfigured = false
            return
        }
        do { try controller.updater.start(); isConfigured = true; errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
    func setAutomaticChecking(_ enabled: Bool) { controller.updater.automaticallyChecksForUpdates = enabled }
    func setAutomaticDownloads(_ enabled: Bool) { controller.updater.automaticallyDownloadsUpdates = enabled }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard TaskProcessingQueue.shared.taskID != nil else { return false }
        deferredInstallation = Task { @MainActor in
            while TaskProcessingQueue.shared.taskID != nil {
                await TaskProcessingQueue.shared.waitUntilIdle()
            }
            guard !Task.isCancelled else { return }
            deferredInstallation = nil
            installHandler()
        }
        return true
    }
}
#endif
