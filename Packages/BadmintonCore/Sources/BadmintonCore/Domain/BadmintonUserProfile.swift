import Foundation

public enum BadmintonUserProfileValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidHeight
    case invalidArmSpan
    case incompleteCalibrationMetadata
}

/// Formal-product profile data. Fields whose required/optional status is still
/// a product decision remain optional, so the storage layer does not turn an
/// unresolved decision into a permanent onboarding gate.
public struct BadmintonUserProfile: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public var heightCentimeters: Double?
    public var armSpanCentimeters: Double?
    public var skillLevelCode: String?
    public var calibrationCompletedAt: Date?
    public var calibrationVersion: String?
    public var onboardingCompleted: Bool
    public var updatedAt: Date

    public init(
        schemaVersion: Int = currentSchemaVersion,
        heightCentimeters: Double? = nil,
        armSpanCentimeters: Double? = nil,
        skillLevelCode: String? = nil,
        calibrationCompletedAt: Date? = nil,
        calibrationVersion: String? = nil,
        onboardingCompleted: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.heightCentimeters = heightCentimeters
        self.armSpanCentimeters = armSpanCentimeters
        self.skillLevelCode = skillLevelCode
        self.calibrationCompletedAt = calibrationCompletedAt
        self.calibrationVersion = calibrationVersion
        self.onboardingCompleted = onboardingCompleted
        self.updatedAt = updatedAt
    }

    public func validate() throws {
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw BadmintonUserProfileValidationError.unsupportedSchemaVersion(
                schemaVersion
            )
        }
        if let heightCentimeters,
           !heightCentimeters.isFinite || heightCentimeters <= 0 {
            throw BadmintonUserProfileValidationError.invalidHeight
        }
        if let armSpanCentimeters,
           !armSpanCentimeters.isFinite || armSpanCentimeters <= 0 {
            throw BadmintonUserProfileValidationError.invalidArmSpan
        }
        let hasCalibrationDate = calibrationCompletedAt != nil
        let hasCalibrationVersion = calibrationVersion?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard hasCalibrationDate == hasCalibrationVersion else {
            throw BadmintonUserProfileValidationError.incompleteCalibrationMetadata
        }
    }
}
