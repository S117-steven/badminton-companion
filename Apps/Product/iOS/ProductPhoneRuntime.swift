import BadmintonCore
import Foundation

final class ProductPhoneRuntime: @unchecked Sendable {
    static let shared = ProductPhoneRuntime()

    let workoutStore: BadmintonWorkoutFileStore
    let profileStore: BadmintonUserProfileFileStore
    let workoutInbox: BadmintonWorkoutTransferInbox

    private init() {
        let root = Self.productDataDirectory
        let workoutStore = BadmintonWorkoutFileStore(
            baseDirectory: root.appendingPathComponent("Workouts", isDirectory: true)
        )
        self.workoutStore = workoutStore
        profileStore = BadmintonUserProfileFileStore(
            directory: root.appendingPathComponent("Profile", isDirectory: true)
        )
        workoutInbox = BadmintonWorkoutTransferInbox(
            stagingDirectory: root.appendingPathComponent(
                "WorkoutInbox",
                isDirectory: true
            ),
            destinationStore: workoutStore
        )
    }

    private static var productDataDirectory: URL {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return documents.appendingPathComponent("ProductData", isDirectory: true)
    }
}
