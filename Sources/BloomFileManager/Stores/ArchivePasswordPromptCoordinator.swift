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

private final class ArchivePasswordPromptTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ArchiveSecret, Error>?
    private var result: Result<ArchiveSecret, Error>?

    var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return result != nil
    }

    func install(_ continuation: CheckedContinuation<ArchiveSecret, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            resume(continuation, with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resolve(returning secret: ArchiveSecret) {
        let continuation: CheckedContinuation<ArchiveSecret, Error>?

        lock.lock()
        guard result == nil else {
            lock.unlock()
            secret.invalidate()
            return
        }
        let result: Result<ArchiveSecret, Error> = .success(secret)
        self.result = result
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        if let continuation {
            resume(continuation, with: result)
        }
    }

    func cancel() {
        let continuation: CheckedContinuation<ArchiveSecret, Error>?

        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        let result: Result<ArchiveSecret, Error> = .failure(CancellationError())
        self.result = result
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        if let continuation {
            resume(continuation, with: result)
        }
    }

    deinit {
        cancel()
    }

    private func resume(
        _ continuation: CheckedContinuation<ArchiveSecret, Error>,
        with result: Result<ArchiveSecret, Error>
    ) {
        switch result {
        case let .success(secret):
            continuation.resume(returning: secret)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}

private final class ArchivePasswordPromptLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var ticket: ArchivePasswordPromptTicket?

    func set(_ ticket: ArchivePasswordPromptTicket?) {
        lock.withLock {
            self.ticket = ticket
        }
    }

    func cancel() {
        let ticket = lock.withLock {
            let ticket = self.ticket
            self.ticket = nil
            return ticket
        }
        ticket?.cancel()
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

    private nonisolated let ticketLifecycle = ArchivePasswordPromptLifecycle()
    private var pendingTicket: ArchivePasswordPromptTicket?
    private var pendingRequestID: UUID?

    deinit {
        ticketLifecycle.cancel()
    }

    func requestPassword(for request: ArchivePasswordRequest) async throws -> ArchiveSecret {
        let ticket = ArchivePasswordPromptTicket()
        try begin(request: request, ticket: ticket)
        do {
            return try await Self.awaitResult(for: ticket)
        } catch {
            // The cancellation handler resumes the ticket from a
            // nonisolated context. Clear observable coordinator state on the
            // main actor before the request task reports its error.
            clearPendingState(if: ticket)
            throw error
        }
    }

    private func begin(
        request: ArchivePasswordRequest,
        ticket: ArchivePasswordPromptTicket
    ) throws {
        // A cancellation handler may have resolved the ticket off-actor just
        // before its weak cleanup hop runs. Reclaim that state before deciding
        // whether another prompt can begin.
        if let pendingTicket, pendingTicket.isResolved {
            clearPendingState(if: pendingTicket)
        }

        guard pendingTicket == nil, pendingRequest == nil else {
            throw ArchivePasswordPromptError.closed
        }

        pendingRequest = request
        validationError = nil
        pendingRequestID = request.id
        pendingTicket = ticket
        ticketLifecycle.set(ticket)
    }

    func submit(password: String, confirmation: String?) {
        guard let request = pendingRequest else { return }
        submit(password: password, confirmation: confirmation, requestID: request.id)
    }

    func submit(
        password: String,
        confirmation: String?,
        requestID: UUID
    ) {
        guard let request = pendingRequest,
              request.id == requestID,
              let ticket = pendingTicket,
              !ticket.isResolved else {
            return
        }

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
                    finishCreating(
                        password: password,
                        confirmation: confirmation,
                        requestID: requestID,
                        ticket: ticket
                    )
                    return
                }
                validationError = error
                return
            }
            validationError = error

        case .extract:
            guard let error = Self.validate(password, minimumBytes: 1, maximumBytes: 1_024) else {
                finishExtracting(password: password, requestID: requestID, ticket: ticket)
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
              let ticket = pendingTicket else {
            return
        }

        clearPendingState()
        ticket.cancel()
    }

    private func finishCreating(
        password: String,
        confirmation: String,
        requestID: UUID,
        ticket: ArchivePasswordPromptTicket
    ) {
        do {
            let secret = try ArchiveSecret.creation(
                password: password,
                confirmation: confirmation
            )
            finish(with: secret, requestID: requestID, ticket: ticket)
        } catch let error as ArchiveSecretError {
            validationError = Self.validationError(for: error, input: password)
        } catch {
            validationError = .invalidLength
        }
    }

    private func finishExtracting(
        password: String,
        requestID: UUID,
        ticket: ArchivePasswordPromptTicket
    ) {
        do {
            finish(
                with: try ArchiveSecret.extraction(password: password),
                requestID: requestID,
                ticket: ticket
            )
        } catch let error as ArchiveSecretError {
            validationError = Self.validationError(for: error, input: password)
        } catch {
            validationError = .invalidLength
        }
    }

    private func finish(
        with secret: ArchiveSecret,
        requestID: UUID,
        ticket: ArchivePasswordPromptTicket
    ) {
        guard pendingRequestID == requestID, pendingTicket === ticket else {
            // Cancellation or a newer request won the race. The ticket owns
            // no successful secret in this branch, so wipe it immediately.
            secret.invalidate()
            return
        }

        clearPendingState()
        ticket.resolve(returning: secret)
    }

    private func clearPendingState() {
        pendingRequest = nil
        validationError = nil
        pendingRequestID = nil
        pendingTicket = nil
        ticketLifecycle.set(nil)
    }

    private func clearPendingState(if ticket: ArchivePasswordPromptTicket) {
        guard pendingTicket === ticket else { return }
        clearPendingState()
    }

    private static func awaitResult(
        for ticket: ArchivePasswordPromptTicket
    ) async throws -> ArchiveSecret {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<ArchiveSecret, Error>) in
                ticket.install(continuation)
            }
        }, onCancel: {
            ticket.cancel()
        })
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
