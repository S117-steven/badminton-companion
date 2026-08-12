import WatchKit

final class ProductWatchApplicationDelegate: NSObject, WKApplicationDelegate {
    func handleActiveWorkoutRecovery() {
        ProductWorkoutRuntime.shared.beginActiveWorkoutRecovery()
    }
}
