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

        coordinator.submit(password: "valid-passphrase", confirmation: "valid-passphrase")
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

        coordinator.submit(password: "short", confirmation: "short")

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

        coordinator.submit(password: "before\0after", confirmation: nil)
        #expect(coordinator.validationError == .containsNull)
        #expect(String(reflecting: coordinator).contains("before") == false)

        coordinator.submit(password: String(repeating: "x", count: 1_024), confirmation: nil)
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
}
