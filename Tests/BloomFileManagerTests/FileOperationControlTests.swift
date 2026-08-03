import Testing
@testable import BloomFileManager

@Suite("FileOperationControlTests")
struct FileOperationControlTests {
    @Test func checkpointReturnsImmediatelyWhileRunning() async throws {
        let control = FileOperationControl()

        try await control.checkpoint()

        #expect(await !control.isPaused)
        #expect(await control.waitingCount == 0)
    }

    @Test func pauseSuspendsCheckpointUntilResume() async throws {
        let control = FileOperationControl()
        await control.pause()
        let completion = CompletionProbe()
        let task = Task {
            try await control.checkpoint()
            await completion.finish()
        }
        await waitForWaiter(in: control)

        #expect(await !completion.isFinished)
        await control.resume()
        try await task.value

        #expect(await completion.isFinished)
        #expect(await control.waitingCount == 0)
    }

    @Test func resumeReleasesEveryPausedCheckpoint() async throws {
        let control = FileOperationControl()
        await control.pause()
        let tasks = (0..<3).map { _ in
            Task { try await control.checkpoint() }
        }
        while await control.waitingCount < 3 {
            await Task.yield()
        }

        await control.resume()
        for task in tasks {
            try await task.value
        }

        #expect(await control.waitingCount == 0)
    }

    @Test func cancellingControlReleasesPausedCheckpointByThrowing() async {
        let control = FileOperationControl()
        await control.pause()
        let task = Task { try await control.checkpoint() }
        await waitForWaiter(in: control)

        await control.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await control.waitingCount == 0)
    }

    @Test func cancellingOneWaitingTaskDoesNotReleaseOtherWaiters() async throws {
        let control = FileOperationControl()
        await control.pause()
        let first = Task { try await control.checkpoint() }
        let second = Task { try await control.checkpoint() }
        while await control.waitingCount < 2 {
            await Task.yield()
        }

        first.cancel()
        await #expect(throws: CancellationError.self) {
            try await first.value
        }
        #expect(await control.waitingCount == 1)

        await control.resume()
        try await second.value
    }

    private func waitForWaiter(in control: FileOperationControl) async {
        while await control.waitingCount == 0 {
            await Task.yield()
        }
    }
}

private actor CompletionProbe {
    private(set) var isFinished = false

    func finish() {
        isFinished = true
    }
}
