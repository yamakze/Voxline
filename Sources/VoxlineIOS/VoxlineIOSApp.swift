import SwiftUI

@main
struct VoxlineIOSApp: App {
    var body: some Scene {
        WindowGroup {
            IOSTaskLibraryView()
                .tint(.primary)
        }
    }
}
