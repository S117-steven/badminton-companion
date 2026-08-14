import BadmintonCore
import Foundation

@MainActor
final class ProductPhoneViewModel: ObservableObject {
    @Published private(set) var workouts: [BadmintonWorkoutRecord] = []
    @Published private(set) var profile: BadmintonUserProfile?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var simulatorMessage: String?

    private let workoutStore: BadmintonWorkoutFileStore
    private let profileStore: BadmintonUserProfileFileStore
    private let workoutInbox: BadmintonWorkoutTransferInbox

    init(runtime: ProductPhoneRuntime = .shared) {
        workoutStore = runtime.workoutStore
        profileStore = runtime.profileStore
        workoutInbox = runtime.workoutInbox
    }

    var needsOnboarding: Bool {
        profile?.onboardingCompleted != true
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let loadedWorkouts = workoutStore.list()
            async let loadedProfile = profileStore.load()
            workouts = try await loadedWorkouts
            profile = try await loadedProfile
            errorMessage = nil
        } catch {
            errorMessage = "无法读取本地数据：\(error.localizedDescription)"
        }
    }

    func saveProfile(
        heightText: String,
        armSpanText: String,
        skillLevelCode: String?,
        onboardingCompleted: Bool
    ) async -> Bool {
        do {
            let height = try optionalPositiveNumber(
                heightText,
                fieldName: "身高"
            )
            let armSpan = try optionalPositiveNumber(
                armSpanText,
                fieldName: "臂展"
            )
            var updated = profile ?? BadmintonUserProfile()
            updated.heightCentimeters = height
            updated.armSpanCentimeters = armSpan
            updated.skillLevelCode = skillLevelCode
            updated.onboardingCompleted = onboardingCompleted
            updated.updatedAt = Date()
            try await profileStore.save(updated)
            profile = updated
            errorMessage = nil
            return true
        } catch {
            if let inputError = error as? ProductProfileInputError {
                errorMessage = inputError.message
            } else {
                errorMessage = "无法保存个人资料：\(error.localizedDescription)"
            }
            return false
        }
    }

    func skipOnboarding() async {
        do {
            var updated = profile ?? BadmintonUserProfile()
            updated.onboardingCompleted = true
            updated.updatedAt = Date()
            try await profileStore.save(updated)
            profile = updated
            errorMessage = nil
        } catch {
            errorMessage = "无法保存首次使用状态：\(error.localizedDescription)"
        }
    }

#if targetEnvironment(simulator)
    func importSimulatorWorkout() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BadmintonProductSimulator-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let sourceStore = BadmintonWorkoutFileStore(baseDirectory: root)
            let end = Date()
            let start = end.addingTimeInterval(-2_730)
            let record = BadmintonWorkoutRecord(
                provenance: .simulatorSynthetic,
                startedAt: start,
                endedAt: end,
                lifecycleState: .completed,
                accumulatedActiveDurationSeconds: 2_580,
                healthAuthorizationState: .simulated,
                healthWriteState: .simulatedNotSaved,
                healthMetrics: .init(
                    averageHeartRateBeatsPerMinute: 137,
                    maximumHeartRateBeatsPerMinute: 169,
                    activeEnergyKilocalories: 286.4,
                    totalEnergyKilocalories: 342.7
                ),
                lastMetricAt: end.addingTimeInterval(-5),
                updatedAt: end
            )
            try await sourceStore.create(record)
            let file = try await sourceStore.storedFile(id: record.id)
            let result = try await workoutInbox.receive(
                fileAt: file.url,
                metadata: .init(
                    workoutID: record.id,
                    schemaVersion: record.schemaVersion,
                    byteCount: file.byteCount
                )
            )
            switch result {
            case .imported:
                simulatorMessage = "已导入一场明确标记的 Simulator 流程运动。"
            case .duplicate:
                simulatorMessage = "该 Simulator 流程运动已经存在。"
            }
            await reload()
        } catch {
            errorMessage = "Simulator 入站检查失败：\(error.localizedDescription)"
        }
    }
#endif

    private func optionalPositiveNumber(
        _ text: String,
        fieldName: String
    ) throws -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Double(trimmed), value.isFinite, value > 0 else {
            throw ProductProfileInputError(message: "\(fieldName)必须是大于 0 的数字。")
        }
        return value
    }
}

private struct ProductProfileInputError: Error {
    let message: String
}
