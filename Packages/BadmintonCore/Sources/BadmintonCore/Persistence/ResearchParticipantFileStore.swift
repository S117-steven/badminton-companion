import Foundation

public enum ResearchParticipantStoreError: Error, Equatable, Sendable {
    case participantNotFound(UUID)
}

public actor ResearchParticipantFileStore {
    private let baseDirectory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func save(_ participant: ResearchParticipant) throws {
        try participant.validate()
        try fileManager.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        try encoder
            .encode(participant)
            .write(to: fileURL(for: participant.id), options: [.atomic])
    }

    public func load(id: UUID) throws -> ResearchParticipant {
        let url = fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ResearchParticipantStoreError.participantNotFound(id)
        }
        return try decoder.decode(ResearchParticipant.self, from: Data(contentsOf: url))
    }

    public func list() throws -> [ResearchParticipant] {
        guard fileManager.fileExists(atPath: baseDirectory.path) else {
            return []
        }

        return try fileManager
            .contentsOfDirectory(
                at: baseDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == "json" }
            .map { try decoder.decode(ResearchParticipant.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func fileURL(for participantID: UUID) -> URL {
        baseDirectory
            .appendingPathComponent(participantID.uuidString.lowercased())
            .appendingPathExtension("json")
    }
}

