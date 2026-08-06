import AppKit

@MainActor
final class ApplicationTerminationCoordinator {
    typealias Reply = @MainActor @Sendable (Bool) -> Void
    typealias Sleep = @MainActor @Sendable (Duration) async -> Void

    private enum State {
        case idle
        case preparing
        case replied
    }

    private weak var operationController: FileOperationController?
    private weak var passwordCoordinator: ArchivePasswordPromptCoordinator?
    private let timeout: Duration
    private let pollInterval: Duration
    private let sleep: Sleep
    private let reply: Reply
    private var state: State = .idle
    private var preparationTask: Task<Void, Never>?

    init(
        operationController: FileOperationController?,
        passwordCoordinator: ArchivePasswordPromptCoordinator?,
        timeout: Duration = .seconds(5),
        pollInterval: Duration = .milliseconds(20),
        sleep: @escaping Sleep = { duration in
            do {
                try await Task.sleep(for: duration)
            } catch {
                // A cancelled poll is followed by deinitialization or a new
                // termination request; no reply is emitted from that path.
            }
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
        preparationTask?.cancel()
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
        }

        guard requiresPreparation else {
            return .terminateNow
        }

        state = .preparing
        operationController?.beginTerminationPreparation()
        passwordCoordinator?.cancel()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.waitForSafeTermination(until: deadline)
        }
        return .terminateLater
    }

    private var requiresPreparation: Bool {
        operationController?.requiresTerminationPreparation == true
            || operationController?.hasRecoveryRequiredResultForTermination == true
            || passwordCoordinator?.pendingRequest != nil
    }

    private func waitForSafeTermination(until deadline: ContinuousClock.Instant) async {
        while state == .preparing {
            if let controller = operationController {
                guard controller.isSafelyIdleForTermination else {
                    if ContinuousClock.now >= deadline {
                        finish(replying: false)
                        return
                    }
                    await sleep(pollInterval)
                    continue
                }
                if controller.hasRecoveryRequiredResultForTermination {
                    finish(replying: false)
                    return
                }
            }

            if passwordCoordinator?.pendingRequest != nil {
                if ContinuousClock.now >= deadline {
                    finish(replying: false)
                    return
                }
                await sleep(pollInterval)
                continue
            }

            finish(replying: true)
            return
        }
    }

    private func finish(replying shouldTerminate: Bool) {
        guard state == .preparing else { return }
        preparationTask = nil
        if shouldTerminate {
            state = .replied
        } else {
            state = .idle
            operationController?.finishTerminationPreparation(restartQueue: true)
        }
        reply(shouldTerminate)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationCoordinator: ApplicationTerminationCoordinator?

    func configureTermination(
        operationController: FileOperationController,
        passwordCoordinator: ArchivePasswordPromptCoordinator
    ) {
        terminationCoordinator = ApplicationTerminationCoordinator(
            operationController: operationController,
            passwordCoordinator: passwordCoordinator,
            reply: { shouldTerminate in
                NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
            }
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
