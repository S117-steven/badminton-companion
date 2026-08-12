import Foundation

public enum ResearchCaptureStoreError: Error, Equatable, Sendable {
    case captureAlreadyExists(UUID)
    case captureNotFound(UUID)
    case captureIsNotCollecting(UUID)
    case captureConflict(UUID)
    case importedSampleCountMismatch(expected: Int, actual: Int)
    case invalidSampleLimit
    case invalidSyncTransition(from: ResearchSyncState, to: ResearchSyncState)
}

public enum ResearchCaptureImportResult: Equatable, Sendable {
    case imported(UUID)
    case duplicate(UUID)
}

public enum ResearchCaptureStoredFileKind: String, Codable, Equatable, Sendable {
    case manifest
    case samples
}

public struct ResearchCaptureStoredFile: Equatable, Sendable {
    public let captureID: UUID
    public let kind: ResearchCaptureStoredFileKind
    public let url: URL
    public let byteCount: Int64

    public init(
        captureID: UUID,
        kind: ResearchCaptureStoredFileKind,
        url: URL,
        byteCount: Int64
    ) {
        self.captureID = captureID
        self.kind = kind
        self.url = url
        self.byteCount = byteCount
    }
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

    @discardableResult
    public func updateResearchMetadata(
        captureID: UUID,
        reviewStatus: ResearchReviewStatus,
        invalidReason: String?,
        notes: String?,
        externalSpeedReference: ExternalSpeedReference?
    ) throws -> ResearchCaptureManifest {
        var manifest = try loadManifest(captureID: captureID)
        manifest.reviewStatus = reviewStatus
        manifest.invalidReason = reviewStatus == .invalid
            ? normalizedText(invalidReason)
            : nil
        manifest.notes = normalizedText(notes)
        if var reference = externalSpeedReference {
            reference.sourceDescription = reference.sourceDescription
                .trimmingCharacters(in: .whitespacesAndNewlines)
            reference.pairingIdentifier = reference.pairingIdentifier
                .trimmingCharacters(in: .whitespacesAndNewlines)
            manifest.externalSpeedReference = reference
        } else {
            manifest.externalSpeedReference = nil
        }
        try manifest.validate()
        try writeManifest(manifest)
        return manifest
    }

    @discardableResult
    public func updateSyncState(
        captureID: UUID,
        to newState: ResearchSyncState
    ) throws -> ResearchCaptureManifest {
        var manifest = try loadManifest(captureID: captureID)
        guard isAllowedSyncTransition(from: manifest.syncState, to: newState) else {
            throw ResearchCaptureStoreError.invalidSyncTransition(
                from: manifest.syncState,
                to: newState
            )
        }
        manifest.syncState = newState
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

    /// Streams and uniformly decimates a capture for UI inspection without
    /// loading the complete high-frequency file into memory.
    public func loadSamples(
        captureID: UUID,
        maximumCount: Int
    ) throws -> [ResearchMotionSample] {
        guard maximumCount > 0 else {
            throw ResearchCaptureStoreError.invalidSampleLimit
        }
        let manifest = try loadManifest(captureID: captureID)
        let url = samplesURL(for: captureID)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ResearchCaptureStoreError.captureNotFound(captureID)
        }

        let stride: Int
        if manifest.sampleCount <= maximumCount {
            stride = 1
        } else if maximumCount == 1 {
            stride = Int.max
        } else {
            stride = max(
                1,
                Int(
                    ceil(
                        Double(manifest.sampleCount - 1) / Double(maximumCount - 1)
                    )
                )
            )
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var samples: [ResearchMotionSample] = []
        samples.reserveCapacity(min(maximumCount + 1, manifest.sampleCount))
        var pending = Data()
        var recordIndex = 0
        var lastLine: Data?
        var lastLineWasSelected = false

        func process(_ line: Data) throws {
            guard !line.isEmpty else { return }
            let isSelected = recordIndex.isMultiple(of: stride)
            if isSelected {
                samples.append(try decoder.decode(ResearchMotionSample.self, from: line))
            }
            lastLine = line
            lastLineWasSelected = isSelected
            recordIndex += 1
        }

        while true {
            let chunk = try handle.read(upToCount: 64 * 1_024) ?? Data()
            if chunk.isEmpty { break }
            pending.append(chunk)
            let lines = pending.split(separator: 0x0A, omittingEmptySubsequences: false)
            guard lines.count > 1 else { continue }
            for line in lines.dropLast() {
                try process(Data(line))
            }
            pending = Data(lines[lines.index(before: lines.endIndex)])
        }
        if !pending.isEmpty {
            try process(pending)
        }

        if samples.count < maximumCount, !lastLineWasSelected, let lastLine {
            samples.append(try decoder.decode(ResearchMotionSample.self, from: lastLine))
        }
        return samples
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

    public func recoverUnfinishedCaptures(
        recoveredAt: Date = Date()
    ) throws -> [ResearchCaptureManifest] {
        let unfinished = try listManifests().filter { $0.state == .collecting }
        return try unfinished.map { manifest in
            var recovered = manifest
            recovered.endedAt = max(recoveredAt, manifest.startedAt)
            recovered.state = .interrupted
            recovered.syncState = .pendingTransfer
            try writeManifest(recovered)
            return recovered
        }
    }

    public func storedFile(
        captureID: UUID,
        kind: ResearchCaptureStoredFileKind
    ) throws -> ResearchCaptureStoredFile {
        _ = try loadManifest(captureID: captureID)
        let url: URL
        switch kind {
        case .manifest:
            url = manifestURL(for: captureID)
        case .samples:
            url = samplesURL(for: captureID)
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return ResearchCaptureStoredFile(
            captureID: captureID,
            kind: kind,
            url: url,
            byteCount: Int64(values.fileSize ?? 0)
        )
    }

    public func importCapture(
        manifest: ResearchCaptureManifest,
        samplesFileURL: URL
    ) throws -> ResearchCaptureImportResult {
        try manifest.validate()
        let actualSampleCount = try countNewlineTerminatedRecords(in: samplesFileURL)
        guard actualSampleCount == manifest.sampleCount else {
            throw ResearchCaptureStoreError.importedSampleCountMismatch(
                expected: manifest.sampleCount,
                actual: actualSampleCount
            )
        }

        try fileManager.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        let destination = captureDirectory(for: manifest.id)
        if fileManager.fileExists(atPath: destination.path) {
            let existing = try loadManifest(captureID: manifest.id)
            let existingSamples = samplesURL(for: manifest.id)
            let existingCount = try countNewlineTerminatedRecords(in: existingSamples)
            if capturesDescribeSameSourceData(existing, manifest),
               existingCount == actualSampleCount,
               fileManager.contentsEqual(
                   atPath: existingSamples.path,
                   andPath: samplesFileURL.path
               ) {
                return .duplicate(manifest.id)
            }
            throw ResearchCaptureStoreError.captureConflict(manifest.id)
        }

        let stagingDirectory = baseDirectory.appendingPathComponent(
            ".incoming-\(manifest.id.uuidString.lowercased())-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: false
            )
            try encoder
                .encode(manifest)
                .write(
                    to: stagingDirectory.appendingPathComponent(Self.manifestFileName),
                    options: [.atomic]
                )
            try fileManager.copyItem(
                at: samplesFileURL,
                to: stagingDirectory.appendingPathComponent(Self.samplesFileName)
            )
            try fileManager.moveItem(at: stagingDirectory, to: destination)
            return .imported(manifest.id)
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }
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

    private func normalizedText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Phone-side review metadata may legitimately change after import. It is
    /// excluded from transport deduplication so an acknowledgement retry can
    /// never overwrite or conflict with that local research work.
    private func capturesDescribeSameSourceData(
        _ lhs: ResearchCaptureManifest,
        _ rhs: ResearchCaptureManifest
    ) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.id == rhs.id
            && lhs.participantID == rhs.participantID
            && lhs.mode == rhs.mode
            && lhs.manualLabel == rhs.manualLabel
            && lhs.provenance == rhs.provenance
            && lhs.startedAt == rhs.startedAt
            && lhs.endedAt == rhs.endedAt
            && lhs.state == rhs.state
            && lhs.device == rhs.device
            && lhs.sampleCount == rhs.sampleCount
            && lhs.quality == rhs.quality
    }

    private func countNewlineTerminatedRecords(in url: URL) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var count = 0
        var lastByte: UInt8?
        while true {
            let data = try handle.read(upToCount: 64 * 1024) ?? Data()
            if data.isEmpty { break }
            count += data.reduce(into: 0) { partial, byte in
                if byte == 0x0A { partial += 1 }
            }
            lastByte = data.last
        }

        if let lastByte, lastByte != 0x0A {
            count += 1
        }
        return count
    }

    private func isAllowedSyncTransition(
        from current: ResearchSyncState,
        to newState: ResearchSyncState
    ) -> Bool {
        if current == newState { return true }
        return switch (current, newState) {
        case (.pendingTransfer, .transferred),
             (.transferred, .pendingTransfer),
             (.pendingTransfer, .acknowledged),
             (.transferred, .acknowledged):
            true
        default:
            false
        }
    }
}
