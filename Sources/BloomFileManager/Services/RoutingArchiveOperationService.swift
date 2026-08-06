import Foundation

/// Routes each archive request independently while preserving input order and
/// concatenating all safe result metadata.
actor RoutingArchiveOperationService: ArchiveOperating {
    typealias Route = ArchiveOperationRoute

    private let ordinary: any ArchiveOperating
    private let protected: any ProtectedZIPOperating

    init(
        ordinary: any ArchiveOperating,
        protected: any ProtectedZIPOperating
    ) {
        self.ordinary = ordinary
        self.protected = protected
    }

    init(
        ordinaryService: any ArchiveOperating,
        protectedService: any ProtectedZIPOperating
    ) {
        self.init(ordinary: ordinaryService, protected: protectedService)
    }

    func route(for request: ArchiveRequest) async -> ArchiveOperationRoute {
        guard request.format == .zip else { return .ordinary }
        if request.kind == .compress {
            return request.protection == .aes256 ? .protected : .ordinary
        }
        return await protected.classify(request)
    }

    func perform(
        _ requests: [ArchiveRequest],
        progress: @escaping ArchiveProgressHandler = { _ in }
    ) async -> FileOperationResult {
        var result = FileOperationResult(outcomes: [])
        for (index, request) in requests.enumerated() {
            if Task.isCancelled {
                let cancelled = requests[index...].map {
                    FileOperationItemOutcome.cancelled(source: representativeSource(for: $0))
                }
                return result.merging(FileOperationResult(outcomes: cancelled))
            }

            let route = await route(for: request)
            let requestResult: FileOperationResult
            switch route {
            case .ordinary:
                requestResult = await ordinary.perform([request], progress: progress)
            case .protected:
                requestResult = await protected.perform([request], progress: progress)
            case .unsupported:
                requestResult = FileOperationResult(outcomes: [
                    .failed(
                        source: representativeSource(for: request),
                        message: ProtectedZIPError.unsupportedEncryption.errorDescription!
                    )
                ])
            }
            result = result.merging(requestResult)
            if requestResult.outcomes.contains(where: isCancelled) {
                let cancelled = requests.dropFirst(index + 1).map {
                    FileOperationItemOutcome.cancelled(source: representativeSource(for: $0))
                }
                result = result.merging(FileOperationResult(outcomes: cancelled))
                break
            }
        }
        return result
    }

    private func representativeSource(for request: ArchiveRequest) -> URL {
        request.verifiedSources.first?.url ?? request.finalDestination
    }

    private func isCancelled(_ outcome: FileOperationItemOutcome) -> Bool {
        if case .cancelled = outcome { return true }
        return false
    }
}
