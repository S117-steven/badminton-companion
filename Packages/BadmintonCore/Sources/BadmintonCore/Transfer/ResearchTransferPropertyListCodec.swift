import Foundation

public enum ResearchTransferMessageType: String, Sendable {
    case captureFile = "capture_file"
    case acknowledgement
    case activeParticipant = "active_participant"
}

public struct ResearchActiveParticipantSelection: Equatable, Sendable {
    public let participantID: UUID

    public init(participantID: UUID) {
        self.participantID = participantID
    }
}

public enum ResearchTransferPropertyListCodecError: Error, Equatable, Sendable {
    case unsupportedMessageType
    case missingOrInvalidField(String)
    case invalidCaptureID
    case invalidParticipantID
    case invalidStoredFileKind
}

public enum ResearchTransferPropertyListCodec {
    public static func encode(
        metadata: ResearchCaptureTransferMetadata
    ) -> [String: Any] {
        [
            "message_type": ResearchTransferMessageType.captureFile.rawValue,
            "capture_id": metadata.captureID.uuidString,
            "schema_version": metadata.schemaVersion,
            "file_kind": metadata.kind.rawValue,
            "byte_count": metadata.byteCount,
        ]
    }

    public static func decodeMetadata(
        _ dictionary: [String: Any]
    ) throws -> ResearchCaptureTransferMetadata {
        guard dictionary["message_type"] as? String
            == ResearchTransferMessageType.captureFile.rawValue else {
            throw ResearchTransferPropertyListCodecError.unsupportedMessageType
        }
        let captureID = try decodeCaptureID(dictionary)
        guard let schemaVersion = dictionary["schema_version"] as? Int else {
            throw ResearchTransferPropertyListCodecError.missingOrInvalidField(
                "schema_version"
            )
        }
        guard let kindValue = dictionary["file_kind"] as? String,
              let kind = ResearchCaptureStoredFileKind(rawValue: kindValue) else {
            throw ResearchTransferPropertyListCodecError.invalidStoredFileKind
        }
        let byteCount: Int64
        if let value = dictionary["byte_count"] as? Int64 {
            byteCount = value
        } else if let value = dictionary["byte_count"] as? Int {
            byteCount = Int64(value)
        } else if let value = dictionary["byte_count"] as? NSNumber {
            byteCount = value.int64Value
        } else {
            throw ResearchTransferPropertyListCodecError.missingOrInvalidField("byte_count")
        }
        return .init(
            captureID: captureID,
            schemaVersion: schemaVersion,
            kind: kind,
            byteCount: byteCount
        )
    }

    public static func encode(
        acknowledgement: ResearchCaptureTransferAcknowledgement
    ) -> [String: Any] {
        [
            "message_type": ResearchTransferMessageType.acknowledgement.rawValue,
            "capture_id": acknowledgement.captureID.uuidString,
            "schema_version": acknowledgement.schemaVersion,
        ]
    }

    public static func decodeAcknowledgement(
        _ dictionary: [String: Any]
    ) throws -> ResearchCaptureTransferAcknowledgement {
        guard dictionary["message_type"] as? String
            == ResearchTransferMessageType.acknowledgement.rawValue else {
            throw ResearchTransferPropertyListCodecError.unsupportedMessageType
        }
        guard let schemaVersion = dictionary["schema_version"] as? Int else {
            throw ResearchTransferPropertyListCodecError.missingOrInvalidField(
                "schema_version"
            )
        }
        return .init(
            captureID: try decodeCaptureID(dictionary),
            schemaVersion: schemaVersion
        )
    }

    public static func encode(
        activeParticipant selection: ResearchActiveParticipantSelection
    ) -> [String: Any] {
        [
            "message_type": ResearchTransferMessageType.activeParticipant.rawValue,
            "participant_id": selection.participantID.uuidString,
        ]
    }

    public static func decodeActiveParticipant(
        _ dictionary: [String: Any]
    ) throws -> ResearchActiveParticipantSelection {
        guard dictionary["message_type"] as? String
            == ResearchTransferMessageType.activeParticipant.rawValue else {
            throw ResearchTransferPropertyListCodecError.unsupportedMessageType
        }
        guard let value = dictionary["participant_id"] as? String else {
            throw ResearchTransferPropertyListCodecError.missingOrInvalidField(
                "participant_id"
            )
        }
        guard let participantID = UUID(uuidString: value) else {
            throw ResearchTransferPropertyListCodecError.invalidParticipantID
        }
        return .init(participantID: participantID)
    }

    private static func decodeCaptureID(
        _ dictionary: [String: Any]
    ) throws -> UUID {
        guard let value = dictionary["capture_id"] as? String else {
            throw ResearchTransferPropertyListCodecError.missingOrInvalidField("capture_id")
        }
        guard let captureID = UUID(uuidString: value) else {
            throw ResearchTransferPropertyListCodecError.invalidCaptureID
        }
        return captureID
    }
}
