import SwiftUI

@main
struct BadmintonResearchWatchApp: App {
    init() {
        WatchResearchConnectivityController.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchResearchHomeView()
        }
    }
}
