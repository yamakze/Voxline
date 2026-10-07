import Foundation

/// Directory notifications cover newly arriving documents as well as already queried iCloud items.
final class SharedFolderPresenter: NSObject, NSFilePresenter, Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue.main
    private let onChange: @Sendable () -> Void

    init(directory: URL, onChange: @escaping @Sendable () -> Void) {
        presentedItemURL = directory
        self.onChange = onChange
    }
    func presentedItemDidChange() { onChange() }
    func presentedItemDidMove(to newURL: URL) { onChange() }
    func presentedSubitemDidAppear(at url: URL) { onChange() }
    func presentedSubitemDidChange(at url: URL) { onChange() }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { onChange() }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        onChange()
        completionHandler(nil)
    }
}
