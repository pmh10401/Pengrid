import Foundation
import Testing
@testable import BloomFileManager

@Suite("ArchivePasswordPromptCoordinatorTests")
struct ArchivePasswordPromptCoordinatorTests {
    @MainActor
    @Test func promptReturnsOneSecretAndRetainsNoPassword() async throws {
        let coordinator = ArchivePasswordPromptCoordinator()
        let request = Self.creationRequest
        let task = Task { try await coordinator.requestPassword(for: request) }

        await Task.yield()
        #expect(coordinator.pendingRequest == request)

        coordinator.submit(
            password: "valid-passphrase",
            confirmation: "valid-passphrase",
            requestID: request.id
        )
        let secret = try await task.value
        #expect(coordinator.pendingRequest == nil)
        #expect(coordinator.validationError == nil)
        #expect(String(reflecting: coordinator).contains("valid-passphrase") == false)
        #expect(String(reflecting: coordinator).contains("ArchiveSecret") == false)
        secret.invalidate()
    }

    @MainActor
    @Test func invalidCreationInputStaysInPromptAsNonSecretValidationState() async {
        let coordinator = ArchivePasswordPromptCoordinator()
        let task = Task { try await coordinator.requestPassword(for: Self.creationRequest) }
        await Task.yield()

        coordinator.submit(
            password: "short",
            confirmation: "short",
            requestID: Self.creationRequest.id
        )

        #expect(coordinator.pendingRequest == Self.creationRequest)
        #expect(coordinator.validationError == .tooShort)
        #expect(String(reflecting: coordinator).contains("short") == false)

        coordinator.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @MainActor
    @Test func extractionAcceptsOneTo1024BytesAndRejectsNullWithoutRetainingInput() async {
        let coordinator = ArchivePasswordPromptCoordinator()
        let task = Task { try await coordinator.requestPassword(for: Self.extractionRequest) }
        await Task.yield()

        coordinator.submit(
            password: "before\0after",
            confirmation: nil,
            requestID: Self.extractionRequest.id
        )
        #expect(coordinator.validationError == .containsNull)
        #expect(String(reflecting: coordinator).contains("before") == false)

        coordinator.submit(
            password: String(repeating: "x", count: 1_024),
            confirmation: nil,
            requestID: Self.extractionRequest.id
        )
        let secret = try? await task.value
        #expect(secret != nil)
        secret?.invalidate()
    }

    @MainActor
    @Test func simultaneousRequestIsRejectedByClosedCoordinatorError() async {
        let coordinator = ArchivePasswordPromptCoordinator()
        let first = Task { try await coordinator.requestPassword(for: Self.creationRequest) }
        await Task.yield()

        await #expect(throws: ArchivePasswordPromptError.closed) {
            try await coordinator.requestPassword(for: Self.extractionRequest)
        }

        coordinator.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
    }

    @MainActor
    @Test func cancelRequestOnlyDismissesMatchingPromptAndResumesOnce() async throws {
        let coordinator = ArchivePasswordPromptCoordinator()
        let first = Task { try await coordinator.requestPassword(for: Self.extractionRequest) }
        await Task.yield()
        let firstID = try #require(coordinator.pendingRequest?.id)

        coordinator.cancel(requestID: UUID())
        #expect(coordinator.pendingRequest?.id == firstID)

        coordinator.cancel(requestID: firstID)
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(coordinator.pendingRequest == nil)

        let secondRequest = ArchivePasswordRequest(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            purpose: .extract,
            archiveBasename: "Report.zip",
            previousAttemptFailed: false
        )
        let second = Task { try await coordinator.requestPassword(for: secondRequest) }
        await Task.yield()
        coordinator.cancel(requestID: firstID)
        #expect(coordinator.pendingRequest == secondRequest)

        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(coordinator.pendingRequest == nil)
    }

    @MainActor
    @Test func staleRequestCannotSubmitIntoANewPrompt() async throws {
        let coordinator = ArchivePasswordPromptCoordinator()
        let requestA = Self.creationRequest
        let taskA = Task { try await coordinator.requestPassword(for: requestA) }
        await Task.yield()
        coordinator.cancel(requestID: requestA.id)
        await #expect(throws: CancellationError.self) { try await taskA.value }

        let requestB = ArchivePasswordRequest(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            purpose: .createAES256,
            archiveBasename: "Report.zip",
            previousAttemptFailed: false
        )
        let taskB = Task { try await coordinator.requestPassword(for: requestB) }
        await Task.yield()

        coordinator.submit(
            password: "stale-sentinel",
            confirmation: "stale-sentinel",
            requestID: requestA.id
        )
        #expect(coordinator.pendingRequest == requestB)
        #expect(coordinator.validationError == nil)
        #expect(String(reflecting: coordinator).contains("stale-sentinel") == false)

        coordinator.submit(
            password: "current-passphrase",
            confirmation: "current-passphrase",
            requestID: requestB.id
        )
        let secret = try await taskB.value
        #expect(String(reflecting: coordinator).contains("stale-sentinel") == false)
        secret.invalidate()
    }

    @MainActor
    @Test func alreadyCancelledBeforeInstallCompletesWithoutShowingPrompt() async {
        let coordinator = ArchivePasswordPromptCoordinator()
        let task = Task { try await coordinator.requestPassword(for: Self.extractionRequest) }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(coordinator.pendingRequest == nil)
        #expect(coordinator.validationError == nil)
    }

    @MainActor
    @Test func duplicateSubmitAndCancelResolveOneContinuationOnly() async throws {
        let coordinator = ArchivePasswordPromptCoordinator()
        let request = Self.creationRequest
        let task = Task { try await coordinator.requestPassword(for: request) }
        await Task.yield()

        coordinator.submit(
            password: "first-passphrase",
            confirmation: "first-passphrase",
            requestID: request.id
        )
        coordinator.submit(
            password: "second-passphrase",
            confirmation: "second-passphrase",
            requestID: request.id
        )
        coordinator.cancel(requestID: request.id)

        let secret = try await task.value
        #expect(coordinator.pendingRequest == nil)
        #expect(String(reflecting: coordinator).contains("second-passphrase") == false)
        secret.invalidate()
    }

    @MainActor
    @Test func cancelThenSubmitResolvesCancellationAndIgnoresLaterInput() async {
        let coordinator = ArchivePasswordPromptCoordinator()
        let request = Self.extractionRequest
        let task = Task { try await coordinator.requestPassword(for: request) }
        await Task.yield()

        coordinator.cancel(requestID: request.id)
        coordinator.submit(
            password: "late-sentinel",
            confirmation: nil,
            requestID: request.id
        )

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(coordinator.pendingRequest == nil)
        #expect(String(reflecting: coordinator).contains("late-sentinel") == false)
    }

    @MainActor
    @Test func submitThenCancelKeepsSuccessfulSecretAndIgnoresCancellation() async throws {
        let coordinator = ArchivePasswordPromptCoordinator()
        let request = Self.extractionRequest
        let task = Task { try await coordinator.requestPassword(for: request) }
        await Task.yield()

        coordinator.submit(
            password: "success-passphrase",
            confirmation: nil,
            requestID: request.id
        )
        coordinator.cancel(requestID: request.id)

        let secret = try await task.value
        #expect(coordinator.pendingRequest == nil)
        secret.invalidate()
    }

    @MainActor
    @Test func coordinatorDeinitCancelsPendingTaskAndReleasesOwner() async {
        var owner: ArchivePasswordPromptCoordinator? = ArchivePasswordPromptCoordinator()
        weak var weakOwner = owner
        let task = Task { [weak owner] in
            try await owner?.requestPassword(for: Self.extractionRequest)
        }
        await Task.yield()
        #expect(owner?.pendingRequest == Self.extractionRequest)
        #expect(weakOwner != nil)

        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(owner?.pendingRequest == nil)
        owner = nil
        #expect(weakOwner == nil)
    }

    @MainActor
    @Test func creationValidationHonorsExactUTF8Boundaries() async throws {
        let tooShort = try await Self.creationOutcome(
            password: String(repeating: "a", count: 7),
            confirmation: String(repeating: "a", count: 7)
        )
        #expect(tooShort.validation == .tooShort)

        let acceptedMinimum = try await Self.creationOutcome(
            password: String(repeating: "a", count: 8),
            confirmation: String(repeating: "a", count: 8)
        )
        #expect(acceptedMinimum.secret != nil)
        acceptedMinimum.secret?.invalidate()

        let acceptedMaximum = try await Self.creationOutcome(
            password: String(repeating: "a", count: 256),
            confirmation: String(repeating: "a", count: 256)
        )
        #expect(acceptedMaximum.secret != nil)
        acceptedMaximum.secret?.invalidate()

        let tooLong = try await Self.creationOutcome(
            password: String(repeating: "a", count: 257),
            confirmation: String(repeating: "a", count: 257)
        )
        #expect(tooLong.validation == .tooLong)

        let nul = try await Self.creationOutcome(
            password: "abcdefgh\0",
            confirmation: "abcdefgh\0"
        )
        #expect(nul.validation == .containsNull)

        let mismatch = try await Self.creationOutcome(
            password: "abcdefgh",
            confirmation: "abcdefgi"
        )
        #expect(mismatch.validation == .confirmationMismatch)
    }

    @MainActor
    @Test func extractionValidationHonorsExactUTF8Boundaries() async throws {
        let empty = try await Self.extractionOutcome(password: "")
        #expect(empty.validation == .empty)

        let minimum = try await Self.extractionOutcome(password: "a")
        #expect(minimum.secret != nil)
        minimum.secret?.invalidate()

        let maximum = try await Self.extractionOutcome(password: String(repeating: "b", count: 1_024))
        #expect(maximum.secret != nil)
        maximum.secret?.invalidate()

        let tooLong = try await Self.extractionOutcome(password: String(repeating: "b", count: 1_025))
        #expect(tooLong.validation == .tooLong)

        let nul = try await Self.extractionOutcome(password: "a\0")
        #expect(nul.validation == .containsNull)
    }

    @MainActor
    @Test func cancellingTaskDismissesMatchingPrompt() async {
        let coordinator = ArchivePasswordPromptCoordinator()
        let task = Task { try await coordinator.requestPassword(for: Self.extractionRequest) }
        await Task.yield()

        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(coordinator.pendingRequest == nil)
        #expect(coordinator.validationError == nil)
    }

    private static let creationRequest = ArchivePasswordRequest(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        purpose: .createAES256,
        archiveBasename: "/private/Report.zip",
        previousAttemptFailed: false
    )

    private static let extractionRequest = ArchivePasswordRequest(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        purpose: .extract,
        archiveBasename: "/private/Report.zip",
        previousAttemptFailed: true
    )

    @MainActor
    private static func creationOutcome(
        password: String,
        confirmation: String
    ) async throws -> (validation: ArchivePasswordValidationError?, secret: ArchiveSecret?) {
        let coordinator = ArchivePasswordPromptCoordinator()
        let task = Task { try await coordinator.requestPassword(for: creationRequest) }
        await Task.yield()
        coordinator.submit(
            password: password,
            confirmation: confirmation,
            requestID: creationRequest.id
        )
        if let validation = coordinator.validationError {
            coordinator.cancel(requestID: creationRequest.id)
            await #expect(throws: CancellationError.self) { try await task.value }
            return (validation, nil)
        }
        return (nil, try await task.value)
    }

    @MainActor
    private static func extractionOutcome(
        password: String
    ) async throws -> (validation: ArchivePasswordValidationError?, secret: ArchiveSecret?) {
        let coordinator = ArchivePasswordPromptCoordinator()
        let task = Task { try await coordinator.requestPassword(for: extractionRequest) }
        await Task.yield()
        coordinator.submit(
            password: password,
            confirmation: nil,
            requestID: extractionRequest.id
        )
        if let validation = coordinator.validationError {
            coordinator.cancel(requestID: extractionRequest.id)
            await #expect(throws: CancellationError.self) { try await task.value }
            return (validation, nil)
        }
        return (nil, try await task.value)
    }

}
