import Foundation

/// Identifies how a capture was produced so synthetic data can never be
/// mistaken for physical Apple Watch measurements.
public enum ResearchDataProvenance: String, Codable, Equatable, Sendable {
    case physicalSensor = "physical_sensor"
    case simulatorSynthetic = "simulator_synthetic"
    case automatedTestFixture = "automated_test_fixture"

    public var isEligibleForPhysicalDataAnalysis: Bool {
        self == .physicalSensor
    }
}

