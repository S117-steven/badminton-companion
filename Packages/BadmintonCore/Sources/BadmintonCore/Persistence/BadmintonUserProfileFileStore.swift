import Foundation

/// Atomic local storage for the one formal-product profile on the phone.
public actor BadmintonUserProfileFileStore {
    public static let fileName = "profile.json"

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL, fileManager: FileManager = .default) {
        fileURL = directory.appendingPathComponent(Self.fileName)
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func load() throws -> BadmintonUserProfile? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let profile = try decoder.decode(
            BadmintonUserProfile.self,
            from: Data(contentsOf: fileURL)
        )
        try profile.validate()
        return profile
    }

    public func save(_ profile: BadmintonUserProfile) throws {
        try profile.validate()
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(profile).write(to: fileURL, options: .atomic)
    }
}
