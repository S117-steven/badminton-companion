import SwiftUI

@main
struct BadmintonResearchApp: App {
    init() {
        PhoneResearchConnectivityController.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            PhoneResearchHomeView()
        }
    }
}
