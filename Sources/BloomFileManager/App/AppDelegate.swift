import AppKit

private final class TerminationPreparationInvalidation: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false

    var isInvalidated: Bool {
        lock.withLock { invalidated }
    }

    func invalidate() {
        lock.withLock {
            invalidated = true
        }
    }
}

@MainActor
private final class TerminationPreparationContext {
    typealias Completion = @MainActor @Sendable (Bool) -> Void
    typealias Sleep = @MainActor @Sendable (Duration) async -> Void

    private weak var operationController: FileOperationController?
    private weak var passwordCoordinator: ArchivePasswordPromptCoordinator?
    private let deadline: ContinuousClock.Instant
    private let pollInterval: Duration
    private let sleep: Sleep
    private let terminationPreparationToken: TerminationPreparationToken?
    private let completion: Completion
    private let invalidation: TerminationPreparationInvalidation
    private var didComplete = false

    init(
        operationController: FileOperationController?,
        passwordCoordinator: ArchivePasswordPromptCoordinator?,
        deadline: ContinuousClock.Instant,
        pollInterval: Duration,
        sleep: @escaping Sleep,
        terminationPreparationToken: TerminationPreparationToken?,
        invalidation: TerminationPreparationInvalidation,
        completion: @escaping Completion
    ) {
        self.operationController = operationController
        self.passwordCoordinator = passwordCoordinator
        self.deadline = deadline
        self.pollInterval = pollInterval
        self.sleep = sleep
        self.terminationPreparationToken = terminationPreparationToken
        self.invalidation = invalidation
        self.completion = completion
    }

    func run() async {
        defer {
            if !didComplete {
                if let terminationPreparationToken {
                    operationController?.finishTerminationPreparation(
                        terminationPreparationToken,
                        restartQueue: true
                    )
                }
            }
        }

        while !invalidation.isInvalidated && !Task.isCancelled {
            if let controller = operationController {
                guard controller.isSafelyIdleForTermination else {
                    if ContinuousClock.now >= deadline {
                        complete(replying: false)
                        return
                    }
                    await sleep(pollInterval)
                    continue
                }
                if controller.hasRecoveryRequiredResultForTermination {
                    complete(replying: false)
                    return
                }
            }

            if passwordCoordinator?.pendingRequest != nil {
                if ContinuousClock.now >= deadline {
                    complete(replying: false)
                    return
                }
                await sleep(pollInterval)
                continue
            }

            complete(replying: true)
            return
        }
    }

    private func complete(replying shouldTerminate: Bool) {
        guard !invalidation.isInvalidated else { return }
        didComplete = true
        invalidation.invalidate()
        completion(shouldTerminate)
    }
}

@MainActor
final class ApplicationTerminationCoordinator {
    typealias Reply = @MainActor @Sendable (Bool) -> Void
    typealias Sleep = @MainActor @Sendable (Duration) async -> Void

    private enum State {
        case idle
        case preparing
        case replied
        case invalidated
    }

    private weak var operationController: FileOperationController?
    private weak var passwordCoordinator: ArchivePasswordPromptCoordinator?
    private let timeout: Duration
    private let pollInterval: Duration
    private let sleep: Sleep
    private let reply: Reply
    private var state: State = .idle
    private var terminationPreparationToken: TerminationPreparationToken?
    private var preparationInvalidation: TerminationPreparationInvalidation?
    private var preparationContext: TerminationPreparationContext?
    private var preparationTask: Task<Void, Never>?

    init(
        operationController: FileOperationController?,
        passwordCoordinator: ArchivePasswordPromptCoordinator?,
        timeout: Duration = .seconds(5),
        pollInterval: Duration = .milliseconds(20),
        sleep: @escaping Sleep = { duration in
            try? await Task.sleep(for: duration)
        },
        reply: @escaping Reply
    ) {
        self.operationController = operationController
        self.passwordCoordinator = passwordCoordinator
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.sleep = sleep
        self.reply = reply
    }

    deinit {
        let terminationPreparationToken = self.terminationPreparationToken
        preparationInvalidation?.invalidate()
        preparationTask?.cancel()
        if let operationController, let terminationPreparationToken {
            Task { @MainActor [weak operationController] in
                operationController?.finishTerminationPreparation(
                    terminationPreparationToken,
                    restartQueue: true
                )
            }
        }
    }

    func invalidate() {
        guard state != .invalidated else { return }
        state = .invalidated
        let terminationPreparationToken = self.terminationPreparationToken
        self.terminationPreparationToken = nil
        preparationInvalidation?.invalidate()
        preparationInvalidation = nil
        preparationContext = nil
        preparationTask?.cancel()
        preparationTask = nil
        if let terminationPreparationToken {
            operationController?.finishTerminationPreparation(
                terminationPreparationToken,
                restartQueue: true
            )
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        applicationShouldTerminate()
    }

    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        switch state {
        case .preparing, .replied:
            // AppKit can ask again while the first request is pending. Keep
            // the original preparation/reply one-shot.
            return .terminateLater
        case .idle:
            break
        case .invalidated:
            return .terminateNow
        }

        guard requiresPreparation else {
            return .terminateNow
        }

        state = .preparing
        let terminationPreparationToken = operationController?.beginTerminationPreparation()
        self.terminationPreparationToken = terminationPreparationToken
        passwordCoordinator?.cancel()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let invalidation = TerminationPreparationInvalidation()
        let context = TerminationPreparationContext(
            operationController: operationController,
            passwordCoordinator: passwordCoordinator,
            deadline: deadline,
            pollInterval: pollInterval,
            sleep: sleep,
            terminationPreparationToken: terminationPreparationToken,
            invalidation: invalidation,
            completion: { [weak self] shouldTerminate in
                self?.finish(replying: shouldTerminate)
            }
        )
        preparationInvalidation = invalidation
        preparationContext = context
        preparationTask = Task { @MainActor [context] in
            await context.run()
        }
        return .terminateLater
    }

    private var requiresPreparation: Bool {
        operationController?.requiresTerminationPreparation == true
            || operationController?.hasRecoveryRequiredResultForTermination == true
            || passwordCoordinator?.pendingRequest != nil
    }

    private func finish(replying shouldTerminate: Bool) {
        guard state == .preparing else { return }
        preparationInvalidation?.invalidate()
        preparationInvalidation = nil
        preparationContext = nil
        preparationTask = nil
        let terminationPreparationToken = self.terminationPreparationToken
        self.terminationPreparationToken = nil
        if shouldTerminate {
            state = .replied
        } else {
            state = .idle
            if let terminationPreparationToken {
                operationController?.finishTerminationPreparation(
                    terminationPreparationToken,
                    restartQueue: true
                )
            }
        }
        reply(shouldTerminate)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationCoordinator: ApplicationTerminationCoordinator?

    func configureTermination(
        operationController: FileOperationController,
        passwordCoordinator: ArchivePasswordPromptCoordinator,
        reply: @escaping ApplicationTerminationCoordinator.Reply = { shouldTerminate in
            NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
        }
    ) {
        terminationCoordinator?.invalidate()
        terminationCoordinator = ApplicationTerminationCoordinator(
            operationController: operationController,
            passwordCoordinator: passwordCoordinator,
            reply: reply
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminationCoordinator?.applicationShouldTerminate() ?? .terminateNow
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
