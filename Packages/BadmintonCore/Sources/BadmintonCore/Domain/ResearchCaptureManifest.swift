import Foundation

public struct SensorStreamQualitySummary: Codable, Equatable, Sendable {
    public let source: ResearchSensorSource
    public var sampleCount: Int
    public var requestedIntervalSeconds: Double?
    public var averageActualIntervalSeconds: Double?
    public var maximumActualIntervalSeconds: Double?
    public var abnormalIntervalCount: Int
    public var suspectedDroppedSampleCount: Int
    public var suspectedSaturationSampleCount: Int

    public init(
        source: ResearchSensorSource,
        sampleCount: Int,
        requestedIntervalSeconds: Double? = nil,
        averageActualIntervalSeconds: Double? = nil,
        maximumActualIntervalSeconds: Double? = nil,
        abnormalIntervalCount: Int = 0,
        suspectedDroppedSampleCount: Int = 0,
        suspectedSaturationSampleCount: Int = 0
    ) {
        self.source = source
        self.sampleCount = sampleCount
        self.requestedIntervalSeconds = requestedIntervalSeconds
        self.averageActualIntervalSeconds = averageActualIntervalSeconds
        self.maximumActualIntervalSeconds = maximumActualIntervalSeconds
        self.abnormalIntervalCount = abnormalIntervalCount
        self.suspectedDroppedSampleCount = suspectedDroppedSampleCount
        self.suspectedSaturationSampleCount = suspectedSaturationSampleCount
    }
}

public struct SamplingQualitySummary: Codable, Equatable, Sendable {
    public var requestedIntervalSeconds: Double?
    public var averageActualIntervalSeconds: Double?
    public var maximumActualIntervalSeconds: Double?
    public var abnormalIntervalCount: Int
    public var suspectedDroppedSampleCount: Int
    public var suspectedSaturationSampleCount: Int
    /// Added in schema v3. Optional so pre-v3 development captures remain readable.
    public var sourceSummaries: [SensorStreamQualitySummary]?

    public init(
        requestedIntervalSeconds: Double? = nil,
        averageActualIntervalSeconds: Double? = nil,
        maximumActualIntervalSeconds: Double? = nil,
        abnormalIntervalCount: Int = 0,
        suspectedDroppedSampleCount: Int = 0,
        suspectedSaturationSampleCount: Int = 0,
        sourceSummaries: [SensorStreamQualitySummary]? = nil
    ) {
        self.requestedIntervalSeconds = requestedIntervalSeconds
        self.averageActualIntervalSeconds = averageActualIntervalSeconds
        self.maximumActualIntervalSeconds = maximumActualIntervalSeconds
        self.abnormalIntervalCount = abnormalIntervalCount
        self.suspectedDroppedSampleCount = suspectedDroppedSampleCount
        self.suspectedSaturationSampleCount = suspectedSaturationSampleCount
        self.sourceSummaries = sourceSummaries
    }
}

public enum ResearchSpeedUnit: String, Codable, Equatable, Sendable {
    case kilometersPerHour = "km/h"
    case metersPerSecond = "m/s"
}

public enum ExternalMeasurementStatus: String, Codable, Equatable, Sendable {
    case pendingReview = "pending_review"
    case verified
    case rejected
}

/// An optional external ground-truth measurement. This is deliberately separate
/// from all future model estimates.
public struct ExternalSpeedReference: Codable, Equatable, Sendable {
    public var measuredValue: Double
    public var unit: ResearchSpeedUnit
    public var sourceDescription: String
    public var status: ExternalMeasurementStatus
    public var pairingIdentifier: String

    public init(
        measuredValue: Double,
        unit: ResearchSpeedUnit,
        sourceDescription: String,
        status: ExternalMeasurementStatus,
        pairingIdentifier: String
    ) {
        self.measuredValue = measuredValue
        self.unit = unit
        self.sourceDescription = sourceDescription
        self.status = status
        self.pairingIdentifier = pairingIdentifier
    }
}

public enum ResearchCaptureValidationError: Error, Equatable, Sendable {
    case missingManualLabel
    case unexpectedManualLabelForFreePlay
    case fixedLabelMismatch
    case endBeforeStart
    case negativeSampleCount
}

public struct ResearchCaptureManifest: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 3

    public let schemaVersion: Int
    public let id: UUID
    public let participantID: UUID
    public let mode: ResearchCaptureMode
    public let manualLabel: ManualActionLabel?
    public let provenance: ResearchDataProvenance
    public let startedAt: Date
    public var endedAt: Date?
    public var state: ResearchCaptureState
    public var reviewStatus: ResearchReviewStatus
    public var invalidReason: String?
    public var notes: String?
    public let device: ResearchDeviceMetadata
    public var sampleCount: Int
    public var quality: SamplingQualitySummary
    public var externalSpeedReference: ExternalSpeedReference?
    public var syncState: ResearchSyncState

    public init(
        schemaVersion: Int = currentSchemaVersion,
        id: UUID = UUID(),
        participantID: UUID,
        mode: ResearchCaptureMode,
        manualLabel: ManualActionLabel?,
        provenance: ResearchDataProvenance,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        state: ResearchCaptureState = .collecting,
        reviewStatus: ResearchReviewStatus = .pending,
        invalidReason: String? = nil,
        notes: String? = nil,
        device: ResearchDeviceMetadata,
        sampleCount: Int = 0,
        quality: SamplingQualitySummary = .init(),
        externalSpeedReference: ExternalSpeedReference? = nil,
        syncState: ResearchSyncState = .localOnly
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.participantID = participantID
        self.mode = mode
        self.manualLabel = manualLabel
        self.provenance = provenance
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.state = state
        self.reviewStatus = reviewStatus
        self.invalidReason = invalidReason
        self.notes = notes
        self.device = device
        self.sampleCount = sampleCount
        self.quality = quality
        self.externalSpeedReference = externalSpeedReference
        self.syncState = syncState
    }

    public func validate() throws {
        if mode == .freePlay, manualLabel != nil {
            throw ResearchCaptureValidationError.unexpectedManualLabelForFreePlay
        }
        if mode.requiresManualLabel, manualLabel == nil {
            throw ResearchCaptureValidationError.missingManualLabel
        }
        if let fixedLabel = mode.fixedManualLabel, manualLabel != fixedLabel {
            throw ResearchCaptureValidationError.fixedLabelMismatch
        }
        if let endedAt, endedAt < startedAt {
            throw ResearchCaptureValidationError.endBeforeStart
        }
        if sampleCount < 0 {
            throw ResearchCaptureValidationError.negativeSampleCount
        }
    }
}
