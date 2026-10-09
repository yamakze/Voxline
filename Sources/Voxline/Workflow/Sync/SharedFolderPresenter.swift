import Foundation

/// Directory notifications cover newly arriving documents as well as already queried iCloud items.
final class SharedFolderPresenter: NSObject, NSFilePresenter, Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue.main
    private let onChange: @Sendable (Set<URL>?) -> Void

    init(directory: URL, onChange: @escaping @Sendable (Set<URL>?) -> Void) {
        presentedItemURL = directory
        self.onChange = onChange
    }
    func presentedItemDidChange() { onChange(nil) }
    func presentedItemDidMove(to newURL: URL) { onChange(nil) }
    func presentedSubitemDidAppear(at url: URL) { onChange([url]) }
    func presentedSubitemDidChange(at url: URL) { onChange([url]) }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { onChange([oldURL, newURL]) }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        onChange([url])
        completionHandler(nil)
    }
}
