import Foundation

public struct ResearchParticipant: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var heightCentimeters: Double
    public var armSpanCentimeters: Double

    /// Versioned research metadata. Product-facing levels remain a product decision.
    public var skillLevelCode: String

    public init(
        id: UUID = UUID(),
        heightCentimeters: Double,
        armSpanCentimeters: Double,
        skillLevelCode: String
    ) {
        self.id = id
        self.heightCentimeters = heightCentimeters
        self.armSpanCentimeters = armSpanCentimeters
        self.skillLevelCode = skillLevelCode
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
