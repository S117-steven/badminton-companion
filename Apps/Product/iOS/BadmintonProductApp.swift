import SwiftUI

@main
struct BadmintonProductApp: App {
    @StateObject private var model = ProductPhoneViewModel()

    init() {
        ProductPhoneConnectivityController.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ProductPhoneRootView(model: model)
        }
    }
}
