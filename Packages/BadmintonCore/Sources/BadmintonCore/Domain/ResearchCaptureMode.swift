import Foundation

/// Internal research modes. These values are not formal product workout modes.
public enum ResearchCaptureMode: String, Codable, CaseIterable, Hashable, Sendable {
    case singleAction = "single_action"
    case normalShotBatch = "normal_shot_batch"
    case smashBatch = "smash_batch"
    case freePlay = "free_play"
    case interference = "interference"

    public var requiresManualLabel: Bool {
        self != .freePlay
    }

    public var fixedManualLabel: ManualActionLabel? {
        switch self {
        case .normalShotBatch:
            return .normalShot
        case .smashBatch:
            return .smash
        case .singleAction, .freePlay, .interference:
            return nil
        }
    }
}

/// A human-provided label selected before or reviewed after collection.
/// No algorithm output may overwrite this value.
public enum ManualActionLabel: String, Codable, CaseIterable, Hashable, Sendable {
    case normalShot = "normal_shot"
    case smash
    case airSwing = "air_swing"
    case running
    case pickingUpShuttle = "picking_up_shuttle"
    case shakingArm = "shaking_arm"
    case wipingSweat = "wiping_sweat"
    case otherInterference = "other_interference"
}

public enum ResearchReviewStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case valid
    case invalid
}

public enum ResearchCaptureState: String, Codable, Hashable, Sendable {
    case collecting
    case completed
    case interrupted
}

public enum ResearchSyncState: String, Codable, Hashable, Sendable {
    case localOnly = "local_only"
    case pendingTransfer = "pending_transfer"
    case transferred
    case acknowledged
}
