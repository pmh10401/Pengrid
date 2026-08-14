import Foundation

protocol SpotlightMetadataQueryRunning: Sendable {
    func matchingURLs(tokens: [String], roots: [URL]) async throws -> [URL]
}

enum SpotlightMetadataQueryError: Error, Equatable, Sendable {
    case unavailable
    case startRejected
}

enum SpotlightContentPredicate {
    static func make(tokens: [String]) -> NSPredicate? {
        guard !tokens.isEmpty, tokens.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        let tokenPredicates = tokens.map {
            NSPredicate(
                format: "%K CONTAINS[cd] %@",
                NSMetadataItemTextContentKey,
                $0
            )
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: tokenPredicates)
    }
}

@MainActor
protocol SpotlightMetadataQuerySession: AnyObject, Sendable {
    func configure(
        predicate: NSPredicate,
        roots: [URL],
        operationQueue: OperationQueue
    )
    func installDidFinishObserver(_ handler: @escaping @MainActor @Sendable () -> Void)
    func startQuery() -> Bool
    func disableUpdates()
    func resultCount() -> Int
    func value(forAttribute attribute: String, at index: Int) -> Any?
    func stopQuery()
    func removeObservers()
}

@MainActor
final class LiveSpotlightMetadataQueryRunner: SpotlightMetadataQueryRunning {
    typealias SessionFactory = @MainActor @Sendable () -> any SpotlightMetadataQuerySession

    private let sessionFactory: SessionFactory

    init(
        sessionFactory: @escaping SessionFactory = {
            LiveSpotlightMetadataQuerySession()
        }
    ) {
        self.sessionFactory = sessionFactory
    }

    func matchingURLs(tokens: [String], roots: [URL]) async throws -> [URL] {
        try Task.checkCancellation()
        guard let predicate = SpotlightContentPredicate.make(tokens: tokens) else {
            throw SpotlightMetadataQueryError.unavailable
        }
        let scopes = standardizedScopes(from: roots)
        guard !scopes.isEmpty else {
            throw SpotlightMetadataQueryError.unavailable
        }

        let call = SpotlightMetadataQueryCall(
            session: sessionFactory(),
            predicate: predicate,
            roots: scopes
        )
        return try await withTaskCancellationHandler {
            try await call.start()
        } onCancel: {
            Task { @MainActor in
                call.cancel()
            }
        }
    }

    private func standardizedScopes(from roots: [URL]) -> [URL] {
        var scopes: [URL] = []
        var seenPaths = Set<String>()
        for root in roots {
            let host = root.host ?? ""
            guard root.isFileURL,
                  root.path.hasPrefix("/"),
                  host.isEmpty || host.caseInsensitiveCompare("localhost") == .orderedSame else {
                return []
            }
            let standardized = root.standardizedFileURL
            if seenPaths.insert(standardized.path).inserted {
                scopes.append(standardized)
            }
        }
        return scopes
    }
}

@MainActor
private final class SpotlightMetadataQueryCall {
    private let session: any SpotlightMetadataQuerySession
    private let predicate: NSPredicate
    private let roots: [URL]
    private var continuation: CheckedContinuation<[URL], Error>?
    private var outcome: Result<[URL], Error>?
    private var updatesDisabled = false
    private var cleanedUp = false

    init(
        session: any SpotlightMetadataQuerySession,
        predicate: NSPredicate,
        roots: [URL]
    ) {
        self.session = session
        self.predicate = predicate
        self.roots = roots
    }

    func start() async throws -> [URL] {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            if outcome != nil {
                resumeIfReady()
                return
            }

            session.configure(
                predicate: predicate,
                roots: roots,
                operationQueue: .main
            )
            session.installDidFinishObserver { [weak self] in
                self?.finishGathering()
            }
            guard session.startQuery() else {
                resolve(.failure(SpotlightMetadataQueryError.startRejected))
                return
            }
        }
    }

    func cancel() {
        resolve(.failure(CancellationError()))
    }

    private func finishGathering() {
        guard outcome == nil else { return }
        disableUpdatesIfNeeded()

        var urls: [URL] = []
        urls.reserveCapacity(session.resultCount())
        for index in 0..<session.resultCount() {
            guard let url = session.value(
                forAttribute: NSMetadataItemURLKey,
                at: index
            ) as? URL else {
                continue
            }
            urls.append(url.standardizedFileURL)
        }
        resolve(.success(urls))
    }

    private func resolve(_ result: Result<[URL], Error>) {
        guard outcome == nil else { return }
        outcome = result
        cleanUpIfNeeded()
        resumeIfReady()
    }

    private func cleanUpIfNeeded() {
        guard !cleanedUp else { return }
        cleanedUp = true
        disableUpdatesIfNeeded()
        session.stopQuery()
        session.removeObservers()
    }

    private func disableUpdatesIfNeeded() {
        guard !updatesDisabled else { return }
        updatesDisabled = true
        session.disableUpdates()
    }

    private func resumeIfReady() {
        guard let continuation, let outcome else { return }
        self.continuation = nil
        switch outcome {
        case let .success(urls):
            continuation.resume(returning: urls)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}

@MainActor
final class LiveSpotlightMetadataQuerySession: SpotlightMetadataQuerySession {
    private let query: NSMetadataQuery
    private let notificationCenter: NotificationCenter
    private var observerTokens: [NSObjectProtocol] = []

    init(
        query: NSMetadataQuery = NSMetadataQuery(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.query = query
        self.notificationCenter = notificationCenter
    }

    func configure(
        predicate: NSPredicate,
        roots: [URL],
        operationQueue: OperationQueue
    ) {
        query.operationQueue = operationQueue
        query.predicate = predicate
        query.searchScopes = roots
    }

    func installDidFinishObserver(_ handler: @escaping @MainActor @Sendable () -> Void) {
        let token = notificationCenter.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                handler()
            }
        }
        observerTokens.append(token)
    }

    func startQuery() -> Bool {
        query.start()
    }

    func disableUpdates() {
        query.disableUpdates()
    }

    func resultCount() -> Int {
        query.resultCount
    }

    func value(forAttribute attribute: String, at index: Int) -> Any? {
        (query.result(at: index) as? NSMetadataItem)?.value(forAttribute: attribute)
    }

    func stopQuery() {
        query.stop()
    }

    func removeObservers() {
        for token in observerTokens {
            notificationCenter.removeObserver(token)
        }
        observerTokens.removeAll()
    }
}
