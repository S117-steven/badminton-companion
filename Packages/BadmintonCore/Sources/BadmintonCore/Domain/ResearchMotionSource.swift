import Foundation

public struct ResearchMotionSourceConfiguration: Equatable, Sendable {
    public var requestedIntervalSeconds: TimeInterval

    public init(requestedIntervalSeconds: TimeInterval) {
        self.requestedIntervalSeconds = requestedIntervalSeconds
    }
}

public struct ResearchMotionSourceFailure: Error, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum ResearchMotionSourceEvent: Sendable {
    case samples([ResearchMotionSample])
    case failure(ResearchMotionSourceFailure)
}

public protocol ResearchMotionSource: Sendable {
    var provenance: ResearchDataProvenance { get }

    func start(
        configuration: ResearchMotionSourceConfiguration,
        onEvent: @escaping @Sendable (ResearchMotionSourceEvent) -> Void
    ) async throws

    func stop() async
}

