import Foundation

public enum ResearchCaptureSessionPhase: String, Codable, Equatable, Sendable {
    case idle
    case preparing
    case collecting
    case stopping
    case completed
    case failed
}

public struct ResearchCaptureSessionSnapshot: Equatable, Sendable {
    public let phase: ResearchCaptureSessionPhase
    public let captureID: UUID?
    public let startedAt: Date?
    public let receivedSampleCount: Int
    public let persistedSampleCount: Int
    public let failure: ResearchMotionSourceFailure?

    public init(
        phase: ResearchCaptureSessionPhase,
        captureID: UUID?,
        startedAt: Date?,
        receivedSampleCount: Int,
        persistedSampleCount: Int,
        failure: ResearchMotionSourceFailure?
    ) {
        self.phase = phase
        self.captureID = captureID
        self.startedAt = startedAt
        self.receivedSampleCount = receivedSampleCount
        self.persistedSampleCount = persistedSampleCount
        self.failure = failure
    }
}

public enum ResearchCaptureSessionError: Error, Equatable, Sendable {
    case sessionAlreadyActive
    case sessionNotActive
    case provenanceMismatch
    case invalidBufferSize
    case invalidEventBufferCapacity
}

public actor ResearchCaptureSessionCoordinator {
    private let store: ResearchCaptureFileStore
    private let flushBatchSize: Int
    private let eventBufferCapacity: Int

    private var phase: ResearchCaptureSessionPhase = .idle
    private var manifest: ResearchCaptureManifest?
    private var source: (any ResearchMotionSource)?
    private var requestedIntervalSeconds: TimeInterval?
    private var buffer: [ResearchMotionSample] = []
    private var receivedSampleCount = 0
    private var persistedSampleCount = 0
    private var intervalTotal = 0.0
    private var intervalCount = 0
    private var maximumInterval: TimeInterval?
    private var failure: ResearchMotionSourceFailure?
    private var captureCreated = false
    private var acceptsSamples = false
    private let overflowTracker = ResearchOverflowTracker()
    private var sourceStatistics: [ResearchSensorSource: SourceStatistics] = [:]
    private var eventContinuation: AsyncStream<ResearchMotionSourceEvent>.Continuation?
    private var eventTask: Task<Void, Never>?

    public init(
        store: ResearchCaptureFileStore,
        flushBatchSize: Int = 100,
        eventBufferCapacity: Int = 2_048
    ) throws {
        guard flushBatchSize > 0 else {
            throw ResearchCaptureSessionError.invalidBufferSize
        }
        guard eventBufferCapacity > 0 else {
            throw ResearchCaptureSessionError.invalidEventBufferCapacity
        }
        self.store = store
        self.flushBatchSize = flushBatchSize
        self.eventBufferCapacity = eventBufferCapacity
    }

    @discardableResult
    public func start(
        manifest: ResearchCaptureManifest,
        source: any ResearchMotionSource,
        configuration: ResearchMotionSourceConfiguration
    ) async throws -> ResearchCaptureSessionSnapshot {
        guard ![.preparing, .collecting, .stopping].contains(phase) else {
            throw ResearchCaptureSessionError.sessionAlreadyActive
        }
        guard manifest.provenance == source.provenance else {
            throw ResearchCaptureSessionError.provenanceMismatch
        }

        try manifest.validate()
        phase = .preparing
        resetCounters()
        self.manifest = manifest
        self.source = source
        requestedIntervalSeconds = configuration.requestedIntervalSeconds

        do {
            try await store.createCapture(manifest)
            captureCreated = true
        } catch {
            failure = ResearchMotionSourceFailure(
                code: "capture_create_failed",
                message: String(describing: error)
            )
            phase = .failed
            self.source = nil
            throw error
        }

        phase = .collecting
        acceptsSamples = true
        let (eventStream, continuation) = AsyncStream<ResearchMotionSourceEvent>.makeStream(
            bufferingPolicy: .bufferingOldest(eventBufferCapacity)
        )
        eventContinuation = continuation
        eventTask = Task { [weak self] in
            for await event in eventStream {
                guard let self else { return }
                await self.receive(event)
            }
        }
        do {
            try await source.start(configuration: configuration) { [weak self] event in
                switch continuation.yield(event) {
                case .dropped(let droppedEvent):
                    let droppedSampleCount: Int
                    switch droppedEvent {
                    case .samples(let samples):
                        droppedSampleCount = samples.count
                    case .failure:
                        droppedSampleCount = 0
                    }
                    self?.overflowTracker.record(
                        droppedSampleCount: droppedSampleCount
                    )
                    Task {
                        await self?.handleEventBufferOverflow()
                    }
                case .enqueued, .terminated:
                    break
                @unknown default:
                    break
                }
            }
            return snapshot()
        } catch {
            let sourceFailure = ResearchMotionSourceFailure(
                code: "source_start_failed",
                message: String(describing: error)
            )
            await fail(sourceFailure)
            throw error
        }
    }

    @discardableResult
    public func stop(at endedAt: Date = Date()) async throws -> ResearchCaptureSessionSnapshot {
        guard phase == .collecting, let captureID = manifest?.id else {
            throw ResearchCaptureSessionError.sessionNotActive
        }

        phase = .stopping
        await source?.stop()
        eventContinuation?.finish()
        await eventTask?.value
        acceptsSamples = false
        eventContinuation = nil
        eventTask = nil
        try await flush()
        let overflowCount = overflowTracker.droppedSampleCount
        if overflowCount > 0 {
            failure = overflowFailure()
        }
        let finished = try await store.finishCapture(
            captureID: captureID,
            endedAt: endedAt,
            state: overflowCount > 0 ? .interrupted : .completed,
            quality: qualitySummary()
        )
        persistedSampleCount = finished.sampleCount
        phase = overflowCount > 0 ? .failed : .completed
        source = nil
        return snapshot()
    }

    @discardableResult
    public func interrupt(at endedAt: Date = Date()) async throws -> ResearchCaptureSessionSnapshot {
        guard [.preparing, .collecting, .stopping].contains(phase),
              let captureID = manifest?.id else {
            throw ResearchCaptureSessionError.sessionNotActive
        }

        phase = .stopping
        await source?.stop()
        eventContinuation?.finish()
        await eventTask?.value
        acceptsSamples = false
        eventContinuation = nil
        eventTask = nil
        try await flush()
        let finished = try await store.finishCapture(
            captureID: captureID,
            endedAt: endedAt,
            state: .interrupted,
            quality: qualitySummary()
        )
        persistedSampleCount = finished.sampleCount
        phase = .completed
        source = nil
        return snapshot()
    }

    public func currentSnapshot() -> ResearchCaptureSessionSnapshot {
        snapshot()
    }

    public func reset() throws {
        guard ![.preparing, .collecting, .stopping].contains(phase) else {
            throw ResearchCaptureSessionError.sessionAlreadyActive
        }
        phase = .idle
        manifest = nil
        source = nil
        eventTask?.cancel()
        eventTask = nil
        eventContinuation = nil
        resetCounters()
    }

    private func receive(_ event: ResearchMotionSourceEvent) async {
        switch event {
        case .samples(let samples):
            guard acceptsSamples,
                  [.collecting, .stopping].contains(phase),
                  !samples.isEmpty else { return }
            receivedSampleCount += samples.count
            recordIntervals(from: samples)
            buffer.append(contentsOf: samples)
            if buffer.count >= flushBatchSize {
                do {
                    try await flush()
                } catch {
                    await fail(
                        .init(code: "persistence_failed", message: String(describing: error))
                    )
                }
            }

        case .failure(let sourceFailure):
            guard [.preparing, .collecting].contains(phase) else { return }
            await fail(sourceFailure)
        }
    }

    private func fail(_ sourceFailure: ResearchMotionSourceFailure) async {
        failure = sourceFailure
        phase = .stopping
        acceptsSamples = false
        await source?.stop()
        eventContinuation?.finish()

        if captureCreated, let captureID = manifest?.id {
            do {
                try await flush()
                let finished = try await store.finishCapture(
                    captureID: captureID,
                    endedAt: Date(),
                    state: .interrupted,
                    quality: qualitySummary()
                )
                persistedSampleCount = finished.sampleCount
            } catch {
                failure = .init(
                    code: "\(sourceFailure.code)+recovery_failed",
                    message: "\(sourceFailure.message); \(error)"
                )
            }
        }

        phase = .failed
        source = nil
        eventContinuation = nil
        eventTask = nil
    }

    private func flush() async throws {
        guard !buffer.isEmpty, let captureID = manifest?.id else { return }
        let samples = buffer
        buffer.removeFirst(samples.count)
        do {
            let updated = try await store.append(samples, to: captureID)
            persistedSampleCount = updated.sampleCount
        } catch {
            buffer.insert(contentsOf: samples, at: buffer.startIndex)
            throw error
        }
    }

    private func recordIntervals(from samples: [ResearchMotionSample]) {
        for sample in samples {
            var statistics = sourceStatistics[sample.source] ?? SourceStatistics()
            statistics.sampleCount += 1
            if let interval = sample.actualIntervalSeconds, interval >= 0 {
                intervalTotal += interval
                intervalCount += 1
                maximumInterval = max(maximumInterval ?? interval, interval)
                statistics.intervalTotal += interval
                statistics.intervalCount += 1
                statistics.maximumInterval = max(
                    statistics.maximumInterval ?? interval,
                    interval
                )
            }
            sourceStatistics[sample.source] = statistics
        }
    }

    private func handleEventBufferOverflow() async {
        guard acceptsSamples, phase == .collecting else { return }
        await fail(overflowFailure())
    }

    private func overflowFailure() -> ResearchMotionSourceFailure {
        .init(
            code: "sample_event_buffer_overflow",
            message: "The bounded sensor event buffer overflowed; capture was interrupted."
        )
    }

    private func qualitySummary() -> SamplingQualitySummary {
        SamplingQualitySummary(
            requestedIntervalSeconds: requestedIntervalSeconds,
            averageActualIntervalSeconds: intervalCount > 0
                ? intervalTotal / Double(intervalCount)
                : nil,
            maximumActualIntervalSeconds: maximumInterval,
            suspectedDroppedSampleCount: overflowTracker.droppedSampleCount,
            sourceSummaries: sourceStatistics
                .map { source, statistics in
                    SensorStreamQualitySummary(
                        source: source,
                        sampleCount: statistics.sampleCount,
                        requestedIntervalSeconds: requestedIntervalSeconds,
                        averageActualIntervalSeconds: statistics.intervalCount > 0
                            ? statistics.intervalTotal / Double(statistics.intervalCount)
                            : nil,
                        maximumActualIntervalSeconds: statistics.maximumInterval
                    )
                }
                .sorted { $0.source.rawValue < $1.source.rawValue }
        )
    }

    private func snapshot() -> ResearchCaptureSessionSnapshot {
        ResearchCaptureSessionSnapshot(
            phase: phase,
            captureID: manifest?.id,
            startedAt: manifest?.startedAt,
            receivedSampleCount: receivedSampleCount,
            persistedSampleCount: persistedSampleCount,
            failure: failure
        )
    }

    private func resetCounters() {
        buffer.removeAll(keepingCapacity: true)
        receivedSampleCount = 0
        persistedSampleCount = 0
        intervalTotal = 0
        intervalCount = 0
        maximumInterval = nil
        failure = nil
        captureCreated = false
        acceptsSamples = false
        overflowTracker.reset()
        sourceStatistics.removeAll(keepingCapacity: true)
    }
}

private struct SourceStatistics: Sendable {
    var sampleCount = 0
    var intervalTotal = 0.0
    var intervalCount = 0
    var maximumInterval: TimeInterval?
}

private final class ResearchOverflowTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDroppedSampleCount = 0

    var droppedSampleCount: Int {
        lock.withLock { storedDroppedSampleCount }
    }

    func record(droppedSampleCount: Int) {
        lock.withLock {
            storedDroppedSampleCount += max(1, droppedSampleCount)
        }
    }

    func reset() {
        lock.withLock {
            storedDroppedSampleCount = 0
        }
    }
}
