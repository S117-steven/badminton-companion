import Foundation

public enum BadmintonWorkoutTransferMessageType: String, Sendable {
    case workoutFile = "workout_file"
    case acknowledgement = "workout_acknowledgement"
}

public enum BadmintonWorkoutTransferCodecError: Error, Equatable, Sendable {
    case unsupportedMessageType
    case missingOrInvalidField(String)
    case invalidWorkoutID
}

public enum BadmintonWorkoutTransferPropertyListCodec {
    public static func encode(
        metadata: BadmintonWorkoutTransferMetadata
    ) -> [String: Any] {
        [
            "message_type": BadmintonWorkoutTransferMessageType.workoutFile.rawValue,
            "workout_id": metadata.workoutID.uuidString,
            "schema_version": metadata.schemaVersion,
            "byte_count": metadata.byteCount,
        ]
    }

    public static func decodeMetadata(
        _ dictionary: [String: Any]
    ) throws -> BadmintonWorkoutTransferMetadata {
        guard dictionary["message_type"] as? String
                == BadmintonWorkoutTransferMessageType.workoutFile.rawValue else {
            throw BadmintonWorkoutTransferCodecError.unsupportedMessageType
        }
        return .init(
            workoutID: try decodeWorkoutID(dictionary),
            schemaVersion: try decodeSchemaVersion(dictionary),
            byteCount: try decodeByteCount(dictionary)
        )
    }

    public static func encode(
        acknowledgement: BadmintonWorkoutTransferAcknowledgement
    ) -> [String: Any] {
        [
            "message_type": BadmintonWorkoutTransferMessageType
                .acknowledgement.rawValue,
            "workout_id": acknowledgement.workoutID.uuidString,
            "schema_version": acknowledgement.schemaVersion,
        ]
    }

    public static func decodeAcknowledgement(
        _ dictionary: [String: Any]
    ) throws -> BadmintonWorkoutTransferAcknowledgement {
        guard dictionary["message_type"] as? String
                == BadmintonWorkoutTransferMessageType.acknowledgement.rawValue else {
            throw BadmintonWorkoutTransferCodecError.unsupportedMessageType
        }
        return .init(
            workoutID: try decodeWorkoutID(dictionary),
            schemaVersion: try decodeSchemaVersion(dictionary)
        )
    }

    private static func decodeWorkoutID(_ dictionary: [String: Any]) throws -> UUID {
        guard let value = dictionary["workout_id"] as? String else {
            throw BadmintonWorkoutTransferCodecError.missingOrInvalidField(
                "workout_id"
            )
        }
        guard let id = UUID(uuidString: value) else {
            throw BadmintonWorkoutTransferCodecError.invalidWorkoutID
        }
        return id
    }

    private static func decodeSchemaVersion(_ dictionary: [String: Any]) throws -> Int {
        guard let value = dictionary["schema_version"] as? Int else {
            throw BadmintonWorkoutTransferCodecError.missingOrInvalidField(
                "schema_version"
            )
        }
        return value
    }

    private static func decodeByteCount(_ dictionary: [String: Any]) throws -> Int64 {
        if let value = dictionary["byte_count"] as? Int64 { return value }
        if let value = dictionary["byte_count"] as? Int { return Int64(value) }
        if let value = dictionary["byte_count"] as? NSNumber {
            return value.int64Value
        }
        throw BadmintonWorkoutTransferCodecError.missingOrInvalidField(
            "byte_count"
        )
    }
}
