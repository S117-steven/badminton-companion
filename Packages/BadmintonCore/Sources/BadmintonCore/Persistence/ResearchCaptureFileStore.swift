import Foundation

public enum ResearchCaptureStoreError: Error, Equatable, Sendable {
    case captureAlreadyExists(UUID)
    case captureNotFound(UUID)
    case captureIsNotCollecting(UUID)
}

/// Append-oriented local storage suitable for watch-offline research capture.
/// Each capture is isolated in its own directory with an atomic manifest and an
/// append-only NDJSON sample stream.
public actor ResearchCaptureFileStore {
    public static let manifestFileName = "manifest.json"
    public static let samplesFileName = "samples.ndjson"

    private let baseDirectory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func createCapture(_ manifest: ResearchCaptureManifest) throws {
        try manifest.validate()
        try fileManager.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )

        let directory = captureDirectory(for: manifest.id)
        guard !fileManager.fileExists(atPath: directory.path) else {
            throw ResearchCaptureStoreError.captureAlreadyExists(manifest.id)
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        try writeManifest(manifest)

        guard fileManager.createFile(atPath: samplesURL(for: manifest.id).path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    @discardableResult
    public func append(
        _ samples: [ResearchMotionSample],
        to captureID: UUID
    ) throws -> ResearchCaptureManifest {
        guard !samples.isEmpty else {
            return try loadManifest(captureID: captureID)
        }

        var manifest = try loadManifest(captureID: captureID)
        guard manifest.state == .collecting else {
            throw ResearchCaptureStoreError.captureIsNotCollecting(captureID)
        }

        var payload = Data()
        for sample in samples {
            payload.append(try encoder.encode(sample))
            payload.append(0x0A)
        }

        let handle = try FileHandle(forWritingTo: samplesURL(for: captureID))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: payload)
        try handle.synchronize()

        manifest.sampleCount += samples.count
        try writeManifest(manifest)
        return manifest
    }

    @discardableResult
    public func finishCapture(
        captureID: UUID,
        endedAt: Date,
        state: ResearchCaptureState = .completed,
        quality: SamplingQualitySummary
    ) throws -> ResearchCaptureManifest {
        var manifest = try loadManifest(captureID: captureID)
        guard manifest.state == .collecting else {
            throw ResearchCaptureStoreError.captureIsNotCollecting(captureID)
        }

        manifest.endedAt = endedAt
        manifest.state = state
        manifest.quality = quality
        manifest.syncState = .pendingTransfer
        try manifest.validate()
        try writeManifest(manifest)
        return manifest
    }

    @discardableResult
    public func updateReview(
        captureID: UUID,
        status: ResearchReviewStatus,
        invalidReason: String? = nil,
        notes: String? = nil
    ) throws -> ResearchCaptureManifest {
        var manifest = try loadManifest(captureID: captureID)
        manifest.reviewStatus = status
        manifest.invalidReason = status == .invalid ? invalidReason : nil
        manifest.notes = notes
        try writeManifest(manifest)
        return manifest
    }

    public func loadManifest(captureID: UUID) throws -> ResearchCaptureManifest {
        let url = manifestURL(for: captureID)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ResearchCaptureStoreError.captureNotFound(captureID)
        }
        return try decoder.decode(ResearchCaptureManifest.self, from: Data(contentsOf: url))
    }

    public func loadSamples(captureID: UUID) throws -> [ResearchMotionSample] {
        let url = samplesURL(for: captureID)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ResearchCaptureStoreError.captureNotFound(captureID)
        }

        let data = try Data(contentsOf: url)
        return try data
            .split(separator: 0x0A)
            .map { try decoder.decode(ResearchMotionSample.self, from: Data($0)) }
    }

    public func listManifests() throws -> [ResearchCaptureManifest] {
        guard fileManager.fileExists(atPath: baseDirectory.path) else {
            return []
        }

        return try fileManager
            .contentsOfDirectory(
                at: baseDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { directory in
                guard let captureID = UUID(uuidString: directory.lastPathComponent) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return try loadManifest(captureID: captureID)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func captureDirectory(for captureID: UUID) -> URL {
        baseDirectory.appendingPathComponent(captureID.uuidString.lowercased(), isDirectory: true)
    }

    private func manifestURL(for captureID: UUID) -> URL {
        captureDirectory(for: captureID).appendingPathComponent(Self.manifestFileName)
    }

    private func samplesURL(for captureID: UUID) -> URL {
        captureDirectory(for: captureID).appendingPathComponent(Self.samplesFileName)
    }

    private func writeManifest(_ manifest: ResearchCaptureManifest) throws {
        try encoder
            .encode(manifest)
            .write(to: manifestURL(for: manifest.id), options: [.atomic])
    }
}
