import Foundation
import Observation

enum ArchivePasswordPromptError: Error, Equatable, LocalizedError, Sendable {
    case closed

    // Keep the public spelling useful to callers that describe the condition
    // as a request already being pending while retaining one closed error.
    static var alreadyPending: Self { .closed }
    static var requestAlreadyPending: Self { .closed }

    var errorDescription: String? {
        "The archive password prompt is already in use."
    }
}

@MainActor
protocol ArchivePasswordProviding: AnyObject, Sendable {
    func requestPassword(for request: ArchivePasswordRequest) async throws -> ArchiveSecret
}

@MainActor @Observable
final class ArchivePasswordPromptCoordinator: ArchivePasswordProviding {
    private(set) var pendingRequest: ArchivePasswordRequest?
    private(set) var validationError: ArchivePasswordValidationError?

    private var pendingContinuation: CheckedContinuation<ArchiveSecret, Error>?
    private var pendingRequestID: UUID?

    func requestPassword(for request: ArchivePasswordRequest) async throws -> ArchiveSecret {
        guard pendingContinuation == nil, pendingRequest == nil else {
            throw ArchivePasswordPromptError.closed
        }

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<ArchiveSecret, Error>) in
                begin(request: request, continuation: continuation)
            }
        }, onCancel: {
            // Cancellation handlers are not isolated to the main actor. Hop
            // back with only the public request ID; no user input crosses the
            // boundary and a stale callback cannot dismiss a newer prompt.
            Task { @MainActor [weak self] in
                self?.cancel(requestID: request.id)
            }
        })
    }

    func submit(password: String, confirmation: String?) {
        guard let request = pendingRequest else { return }

        switch request.purpose {
        case .createAES256:
            guard let confirmation else {
                validationError = .confirmationMismatch
                return
            }
            guard let error = Self.validate(password, minimumBytes: 8, maximumBytes: 256) else {
                guard let error = Self.validate(
                    confirmation,
                    minimumBytes: 8,
                    maximumBytes: 256
                ) else {
                    guard password == confirmation else {
                        validationError = .confirmationMismatch
                        return
                    }
                    finishCreating(password: password, confirmation: confirmation)
                    return
                }
                validationError = error
                return
            }
            validationError = error

        case .extract:
            guard let error = Self.validate(password, minimumBytes: 1, maximumBytes: 1_024) else {
                finishExtracting(password: password)
                return
            }
            validationError = error
        }
    }

    func cancel() {
        guard let requestID = pendingRequest?.id else { return }
        cancel(requestID: requestID)
    }

    func cancel(requestID: UUID) {
        guard pendingRequestID == requestID,
              let continuation = pendingContinuation else {
            return
        }

        clearPendingState()
        continuation.resume(throwing: CancellationError())
    }

    private func begin(
        request: ArchivePasswordRequest,
        continuation: CheckedContinuation<ArchiveSecret, Error>
    ) {
        guard pendingContinuation == nil, pendingRequest == nil else {
            continuation.resume(throwing: ArchivePasswordPromptError.closed)
            return
        }

        // A task cancelled before its continuation is installed must not
        // leave a visible prompt behind. The cancellation handler also runs,
        // but the ID match keeps that later callback harmless.
        guard !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }

        pendingRequest = request
        validationError = nil
        pendingRequestID = request.id
        pendingContinuation = continuation
    }

    private func finishCreating(password: String, confirmation: String) {
        do {
            let secret = try ArchiveSecret.creation(
                password: password,
                confirmation: confirmation
            )
            finish(with: secret)
        } catch let error as ArchiveSecretError {
            validationError = Self.validationError(for: error, input: password)
        } catch {
            validationError = .invalidLength
        }
    }

    private func finishExtracting(password: String) {
        do {
            finish(with: try ArchiveSecret.extraction(password: password))
        } catch let error as ArchiveSecretError {
            validationError = Self.validationError(for: error, input: password)
        } catch {
            validationError = .invalidLength
        }
    }

    private func finish(with secret: ArchiveSecret) {
        guard let continuation = pendingContinuation else {
            // This should only be reachable if a future caller changes the
            // state machine. Avoid retaining the secret if no waiter exists.
            secret.invalidate()
            return
        }

        clearPendingState()
        continuation.resume(returning: secret)
    }

    private func clearPendingState() {
        pendingRequest = nil
        validationError = nil
        pendingRequestID = nil
        pendingContinuation = nil
    }

    private static func validate(
        _ input: String,
        minimumBytes: Int,
        maximumBytes: Int
    ) -> ArchivePasswordValidationError? {
        if input.isEmpty { return .empty }
        if input.unicodeScalars.contains(where: { $0.value == 0 }) {
            return .containsNull
        }
        let byteCount = input.utf8.count
        if byteCount < minimumBytes { return .tooShort }
        if byteCount > maximumBytes { return .tooLong }
        return nil
    }

    private static func validationError(
        for error: ArchiveSecretError,
        input: String
    ) -> ArchivePasswordValidationError {
        switch error {
        case .containsNull:
            return .containsNull
        case .confirmationMismatch:
            return .confirmationMismatch
        case .invalidLength:
            return input.isEmpty ? .empty : .invalidLength
        case .unavailable:
            return .invalidLength
        }
    }
}
