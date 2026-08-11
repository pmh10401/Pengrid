import Foundation
@testable import BloomFileManager

actor InMemoryCloudMaterializer: CloudMaterializing {
    struct Call: Sendable {
        let requests: [IdentifiedFileRequest]
        let purpose: CloudPreparationPurpose
    }

    private let result: CloudMaterializationResult?
    private var calls: [Call] = []

    init(result: CloudMaterializationResult? = nil) {
        self.result = result
    }

    func materialize(
        _ requests: [IdentifiedFileRequest],
        purpose: CloudPreparationPurpose,
        progress: @Sendable (CloudMaterializationProgress) async -> Void
    ) async -> CloudMaterializationResult {
        calls.append(Call(requests: requests, purpose: purpose))
        if let result {
            return result
        }
        return CloudMaterializationResult(
            preparedRequests: requests,
            failures: [],
            wasCancelled: false
        )
    }

    func recordedCalls() -> [Call] {
        calls
    }
}

@MainActor
extension FileOperationController {
    convenience init(
        service: FileOperationService,
        batchRenameService: BatchRenameTransactionService? = nil
    ) {
        self.init(
            service: service,
            materializer: InMemoryCloudMaterializer(),
            batchRenameService: batchRenameService
        )
    }
}
