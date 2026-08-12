import SwiftUI
import WatchKit

@main
struct BadmintonProductWatchApp: App {
    @WKApplicationDelegateAdaptor(ProductWatchApplicationDelegate.self)
    private var applicationDelegate

    var body: some Scene {
        WindowGroup {
            ProductWatchRootView()
        }
    }
}
