import Foundation
import Testing
@testable import BloomFileManager

@Suite("GetInfoInspectorModelTests")
@MainActor
struct GetInfoInspectorModelTests {
    @Test func replacementInspectionCannotPublishAfterNewerSelection() async throws {
        let inspector = DeferredGetInfoInspector()
        let model = GetInfoInspectorModel(inspector: inspector, checksumService: DeferredChecksumService())

        model.inspect([item(named: "first.txt")])
        #expect(await waitForInspectorCondition { await inspector.requestCount == 1 })
        model.inspect([item(named: "second.txt")])
        #expect(await waitForInspectorCondition { await inspector.requestCount == 2 })

        await inspector.complete(requestAt: 0, with: report(named: "first.txt"))
        await inspector.complete(requestAt: 1, with: report(named: "second.txt"))

        #expect(await waitForInspectorCondition { model.phase == .loaded })
        #expect(model.report?.successfulSnapshots.map(\.name) == ["second.txt"])
    }

    @Test func closingCancelsInspectionAndClearsPublishedReport() async throws {
        let inspector = DeferredGetInfoInspector()
        let model = GetInfoInspectorModel(inspector: inspector, checksumService: DeferredChecksumService())

        model.inspect([item(named: "pending.txt")])
        #expect(await waitForInspectorCondition { await inspector.requestCount == 1 })
        model.cancelAndClear()

        #expect(await waitForInspectorCondition { await inspector.cancelledCount == 1 })
        #expect(model.phase == .idle)
        #expect(model.report == nil)
        #expect(model.checksumPhase == .unavailable)
    }

    @Test func activeInspectionServiceCancellationBecomesFailure() async throws {
        let model = GetInfoInspectorModel(
            inspector: IndependentlyCancellingInspector(),
            checksumService: DeferredChecksumService()
        )

        model.inspect([item(named: "unavailable.txt")])

        #expect(await waitForInspectorCondition { model.phase == .failed })
        #expect(model.report == nil)
    }

    @Test func inspectionAloneNeverRequestsChecksum() async throws {
        let inspector = DeferredGetInfoInspector()
        let checksum = DeferredChecksumService()
        let model = GetInfoInspectorModel(inspector: inspector, checksumService: checksum)

        model.inspect([item(named: "document.txt")])
        #expect(await waitForInspectorCondition { await inspector.requestCount == 1 })
        await inspector.complete(requestAt: 0, with: report(named: "document.txt"))

        #expect(await waitForInspectorCondition { model.phase == .loaded })
        #expect(model.checksumPhase == .ready)
        #expect(await checksum.requestCount == 0)
    }

    @Test func explicitChecksumPublishesProgressAndLowercaseHexDigest() async throws {
        let inspector = DeferredGetInfoInspector()
        let checksum = DeferredChecksumService()
        let model = GetInfoInspectorModel(inspector: inspector, checksumService: checksum)

        model.inspect([item(named: "document.txt")])
        #expect(await waitForInspectorCondition { await inspector.requestCount == 1 })
        await inspector.complete(requestAt: 0, with: report(named: "document.txt"))
        #expect(await waitForInspectorCondition { model.phase == .loaded })

        model.calculateSHA256()
        #expect(await waitForInspectorCondition { await checksum.requestCount == 1 })
        await checksum.publishProgress(1.4, forRequestAt: 0)
        #expect(await waitForInspectorCondition {
            model.checksumPhase == .calculating(progress: 1)
        })
        await checksum.complete(requestAt: 0, with: .init(digest: Data([0xAB, 0x00, 0x7F])))

        #expect(await waitForInspectorCondition {
            model.checksumPhase == .complete(hexDigest: "ab007f")
        })
    }

    @Test func explicitChecksumRejectsChangedIdentityAndShowsFailure() async throws {
        let inspector = DeferredGetInfoInspector()
        let checksum = DeferredChecksumService()
        let model = GetInfoInspectorModel(inspector: inspector, checksumService: checksum)

        model.inspect([item(named: "document.txt")])
        #expect(await waitForInspectorCondition { await inspector.requestCount == 1 })
        await inspector.complete(requestAt: 0, with: report(named: "document.txt"))
        #expect(await waitForInspectorCondition { model.phase == .loaded })

        model.calculateSHA256()
        #expect(await waitForInspectorCondition { await checksum.requestCount == 1 })
        await checksum.fail(requestAt: 0, with: ChecksumError.identityChanged)

        #expect(await waitForInspectorCondition { model.checksumPhase == .failed })
    }

    @Test func activeChecksumServiceCancellationBecomesRetryableFailure() async throws {
        let inspector = DeferredGetInfoInspector()
        let checksum = DeferredChecksumService()
        let model = GetInfoInspectorModel(inspector: inspector, checksumService: checksum)

        model.inspect([item(named: "document.txt")])
        #expect(await waitForInspectorCondition { await inspector.requestCount == 1 })
        await inspector.complete(requestAt: 0, with: report(named: "document.txt"))
        #expect(await waitForInspectorCondition { model.phase == .loaded })

        model.calculateSHA256()
        #expect(await waitForInspectorCondition { await checksum.requestCount == 1 })
        await checksum.fail(requestAt: 0, with: CancellationError())

        #expect(await waitForInspectorCondition { model.checksumPhase == .failed })
    }

    @Test func closingCancelsAnActiveChecksum() async throws {
        let inspector = DeferredGetInfoInspector()
        let checksum = DeferredChecksumService()
        let model = GetInfoInspectorModel(inspector: inspector, checksumService: checksum)

        model.inspect([item(named: "document.txt")])
        #expect(await waitForInspectorCondition { await inspector.requestCount == 1 })
        await inspector.complete(requestAt: 0, with: report(named: "document.txt"))
        #expect(await waitForInspectorCondition { model.phase == .loaded })
        model.calculateSHA256()
        #expect(await waitForInspectorCondition { await checksum.requestCount == 1 })

        model.cancelAndClear()

        #expect(await waitForInspectorCondition { await checksum.cancelledCount == 1 })
        #expect(model.phase == .idle)
        #expect(model.report == nil)
        #expect(model.checksumPhase == .unavailable)
    }
}

private actor DeferredGetInfoInspector: GetInfoInspecting {
    private var continuations: [CheckedContinuation<GetInfoInspectionReport, any Error>] = []
    private(set) var requestCount = 0
    private(set) var cancelledCount = 0

    func inspect(_ items: [FileItem]) async throws -> GetInfoInspectionReport {
        requestCount += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuations.append($0) }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
    }

    func complete(requestAt index: Int, with report: GetInfoInspectionReport) {
        continuations[index].resume(returning: report)
    }

    private func recordCancellation() { cancelledCount += 1 }
}

private actor IndependentlyCancellingInspector: GetInfoInspecting {
    func inspect(_ items: [FileItem]) async throws -> GetInfoInspectionReport {
        throw CancellationError()
    }
}

private actor DeferredChecksumService: ChecksumService {
    private struct Request {
        let progress: @Sendable (Double) async -> Void
        let continuation: CheckedContinuation<ChecksumResult, any Error>
    }

    private var requests: [Request] = []
    private(set) var requestCount = 0
    private(set) var cancelledCount = 0

    func checksum(
        for request: ChecksumRequest,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> ChecksumResult {
        requestCount += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { requests.append(.init(progress: progress, continuation: $0)) }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
    }

    func publishProgress(_ value: Double, forRequestAt index: Int) async {
        await requests[index].progress(value)
    }

    func complete(requestAt index: Int, with result: ChecksumResult) {
        requests[index].continuation.resume(returning: result)
    }

    func fail(requestAt index: Int, with error: any Error) {
        requests[index].continuation.resume(throwing: error)
    }

    private func recordCancellation() { cancelledCount += 1 }
}

private func item(named name: String) -> FileItem {
    FileItem(
        url: URL(fileURLWithPath: "/tmp/GetInfoInspectorTests/\(name)"),
        name: name,
        isDirectory: false,
        isPackage: false,
        modifiedAt: Date(timeIntervalSince1970: 1),
        byteSize: 3,
        typeDescription: "Plain text"
    )
}

private func report(named name: String) -> GetInfoInspectionReport {
    let url = URL(fileURLWithPath: "/tmp/GetInfoInspectorTests/\(name)")
    let identity = FileIdentity(entryIdentifier: name, resolvedIdentifier: name)
    let request = ChecksumRequest(
        url: url,
        fingerprint: .init(identity: identity, byteSize: 3, modifiedAt: Date(timeIntervalSince1970: 1))
    )
    return .init(outcomes: [.success(.init(
        url: url,
        name: name,
        kind: .regularFile,
        typeDescription: "Plain text",
        typeIdentifier: "public.plain-text",
        logicalByteSize: 3,
        allocatedByteSize: 4_096,
        createdAt: Date(timeIntervalSince1970: 0),
        modifiedAt: Date(timeIntervalSince1970: 1),
        ownerID: 501,
        groupID: 20,
        posixMode: 0o644,
        finderTags: ["Work"],
        symbolicLinkDestination: nil,
        availability: .availableLocally,
        identity: identity,
        checksumRequest: request
    ))])
}

private func waitForInspectorCondition(
    timeout: Duration = .seconds(1),
    _ condition: @escaping @MainActor @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        guard clock.now < deadline else {
            Issue.record("Timed out waiting for inspector condition.")
            return false
        }
        await Task.yield()
    }
    return true
}
