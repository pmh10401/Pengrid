import Foundation
import Observation

enum GetInfoInspectorPhase: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed
}

enum GetInfoChecksumPhase: Equatable, Sendable {
    case unavailable
    case ready
    case calculating(progress: Double)
    case complete(hexDigest: String)
    case failed
}

private struct GetInfoChecksumProgressRelay: Sendable {
    let stream: AsyncStream<Double>
    private let continuation: AsyncStream<Double>.Continuation

    init() {
        let pair = AsyncStream<Double>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream
        continuation = pair.continuation
    }

    func yield(_ value: Double) {
        continuation.yield(value)
    }

    func finish() {
        continuation.finish()
    }
}

@MainActor
@Observable
final class GetInfoInspectorModel {
    private(set) var phase: GetInfoInspectorPhase = .idle
    private(set) var report: GetInfoInspectionReport?
    private(set) var checksumPhase: GetInfoChecksumPhase = .unavailable

    private let inspector: any GetInfoInspecting
    private let checksumService: any ChecksumService
    private var inspectionTask: Task<Void, Never>?
    private var checksumTask: Task<Void, Never>?
    private var checksumProgressTask: Task<Void, Never>?
    private var checksumProgressRelay: GetInfoChecksumProgressRelay?
    private var generation = 0
    private var checksumGeneration = 0

    init(
        inspector: any GetInfoInspecting = LiveGetInfoInspectionService(),
        checksumService: any ChecksumService = LiveChecksumService()
    ) {
        self.inspector = inspector
        self.checksumService = checksumService
    }

    func inspect(_ items: [FileItem]) {
        generation &+= 1
        let inspectionGeneration = generation
        cancelWork()
        report = nil
        checksumPhase = .unavailable
        phase = .loading

        let inspector = inspector
        inspectionTask = Task { @MainActor [weak self, inspector] in
            do {
                let inspectedReport = try await inspector.inspect(items)
                guard !Task.isCancelled else { return }
                self?.publish(inspectedReport, for: inspectionGeneration)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.publishInspectionFailure(for: inspectionGeneration)
            }
        }
    }

    func calculateSHA256() {
        guard phase == .loaded,
              let request = report?.summary.checksumRequest
        else {
            return
        }

        cancelChecksumWork()
        checksumGeneration &+= 1
        let activeGeneration = generation
        let activeChecksumGeneration = checksumGeneration
        checksumPhase = .calculating(progress: 0)

        let relay = GetInfoChecksumProgressRelay()
        checksumProgressRelay = relay
        checksumProgressTask = Task { @MainActor [weak self] in
            for await progress in relay.stream {
                guard !Task.isCancelled else { return }
                self?.publishChecksumProgress(
                    progress,
                    generation: activeGeneration,
                    checksumGeneration: activeChecksumGeneration
                )
            }
        }

        let checksumService = checksumService
        checksumTask = Task { @MainActor [weak self, checksumService] in
            do {
                let result = try await checksumService.checksum(for: request, progress: relay.yield)
                relay.finish()
                guard !Task.isCancelled else { return }
                self?.publishChecksum(
                    result,
                    generation: activeGeneration,
                    checksumGeneration: activeChecksumGeneration
                )
            } catch is CancellationError {
                relay.finish()
            } catch {
                relay.finish()
                guard !Task.isCancelled else { return }
                self?.publishChecksumFailure(
                    generation: activeGeneration,
                    checksumGeneration: activeChecksumGeneration
                )
            }
        }
    }

    func cancelAndClear() {
        generation &+= 1
        checksumGeneration &+= 1
        cancelWork()
        phase = .idle
        report = nil
        checksumPhase = .unavailable
    }

    private func publish(_ inspectedReport: GetInfoInspectionReport, for expectedGeneration: Int) {
        guard expectedGeneration == generation else { return }
        report = inspectedReport
        phase = .loaded
        checksumPhase = inspectedReport.summary.checksumRequest == nil ? .unavailable : .ready
        inspectionTask = nil
    }

    private func publishInspectionFailure(for expectedGeneration: Int) {
        guard expectedGeneration == generation else { return }
        report = nil
        checksumPhase = .unavailable
        phase = .failed
        inspectionTask = nil
    }

    private func publishChecksumProgress(
        _ progress: Double,
        generation expectedGeneration: Int,
        checksumGeneration expectedChecksumGeneration: Int
    ) {
        guard expectedGeneration == generation,
              expectedChecksumGeneration == checksumGeneration,
              phase == .loaded
        else { return }
        checksumPhase = .calculating(progress: min(1, max(0, progress)))
    }

    private func publishChecksum(
        _ result: ChecksumResult,
        generation expectedGeneration: Int,
        checksumGeneration expectedChecksumGeneration: Int
    ) {
        guard expectedGeneration == generation,
              expectedChecksumGeneration == checksumGeneration,
              phase == .loaded
        else { return }
        checksumPhase = .complete(hexDigest: result.digest.map { String(format: "%02x", $0) }.joined())
        finishChecksumWork()
    }

    private func publishChecksumFailure(
        generation expectedGeneration: Int,
        checksumGeneration expectedChecksumGeneration: Int
    ) {
        guard expectedGeneration == generation,
              expectedChecksumGeneration == checksumGeneration,
              phase == .loaded
        else { return }
        checksumPhase = .failed
        finishChecksumWork()
    }

    private func cancelWork() {
        inspectionTask?.cancel()
        inspectionTask = nil
        cancelChecksumWork()
    }

    private func cancelChecksumWork() {
        checksumProgressRelay?.finish()
        checksumProgressRelay = nil
        checksumProgressTask?.cancel()
        checksumProgressTask = nil
        checksumTask?.cancel()
        checksumTask = nil
    }

    private func finishChecksumWork() {
        checksumProgressRelay?.finish()
        checksumProgressRelay = nil
        checksumProgressTask?.cancel()
        checksumProgressTask = nil
        checksumTask = nil
    }
}
