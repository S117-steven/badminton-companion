import Foundation

public struct ResearchParticipant: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var heightCentimeters: Double
    public var armSpanCentimeters: Double

    /// Versioned research metadata. Product-facing levels remain a product decision.
    public var skillLevelCode: String
    public var skillLevelDefinitionVersion: Int
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        heightCentimeters: Double,
        armSpanCentimeters: Double,
        skillLevelCode: String,
        skillLevelDefinitionVersion: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.heightCentimeters = heightCentimeters
        self.armSpanCentimeters = armSpanCentimeters
        self.skillLevelCode = skillLevelCode
        self.skillLevelDefinitionVersion = skillLevelDefinitionVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ResearchParticipantValidationError: Error, Equatable, Sendable {
    case invalidHeight
    case invalidArmSpan
    case missingSkillLevelCode
    case invalidSkillLevelDefinitionVersion
}

public extension ResearchParticipant {
    func validate() throws {
        guard heightCentimeters.isFinite, heightCentimeters > 0 else {
            throw ResearchParticipantValidationError.invalidHeight
        }
        guard armSpanCentimeters.isFinite, armSpanCentimeters > 0 else {
            throw ResearchParticipantValidationError.invalidArmSpan
        }
        guard !skillLevelCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ResearchParticipantValidationError.missingSkillLevelCode
        }
        guard skillLevelDefinitionVersion > 0 else {
            throw ResearchParticipantValidationError.invalidSkillLevelDefinitionVersion
        }
    }
}


public struct ResearchDeviceMetadata: Codable, Equatable, Sendable {
    public var hardwareModel: String
    public var operatingSystemVersion: String
    public var applicationVersion: String
    public var applicationBuild: String

    public init(
        hardwareModel: String,
        operatingSystemVersion: String,
        applicationVersion: String,
        applicationBuild: String
    ) {
        self.hardwareModel = hardwareModel
        self.operatingSystemVersion = operatingSystemVersion
        self.applicationVersion = applicationVersion
        self.applicationBuild = applicationBuild
    }
}
