import SwiftUI
import WatchKit

@main
struct BadmintonProductWatchApp: App {
    @WKApplicationDelegateAdaptor(ProductWatchApplicationDelegate.self)
    private var applicationDelegate

    init() {
        ProductWorkoutConnectivityController.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ProductWatchRootView()
        }
    }
}
