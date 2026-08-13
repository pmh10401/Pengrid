import Foundation

final class WorkspaceSessionPersistence: @unchecked Sendable {
    static let storageKey = "workspace.session.v2"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> WorkspaceSessionEnvelope? {
        guard let data = defaults.data(forKey: Self.storageKey) else { return nil }
        return try? Self.decoder().decode(WorkspaceSessionEnvelope.self, from: data)
    }

    @discardableResult
    func save(_ envelope: WorkspaceSessionEnvelope) -> Bool {
        guard let validated = try? envelope.validated(),
              let data = try? Self.encoder().encode(validated)
        else { return false }

        defaults.set(data, forKey: Self.storageKey)
        return true
    }

    func restore(
        legacy: WorkspaceSnapshot?,
        home: URL,
        downloads: URL,
        isDirectory: (URL) -> Bool
    ) -> RestoredWorkspaceSession {
        if defaults.object(forKey: Self.storageKey) != nil {
            guard let envelope = load() else {
                return Self.defaultSession(home: home, downloads: downloads)
            }
            return Self.restore(
                envelope,
                home: home,
                downloads: downloads,
                isDirectory: isDirectory
            )
        }

        guard let legacy else {
            return Self.defaultSession(home: home, downloads: downloads)
        }

        let descriptor = Self.repairedDescriptor(
            from: legacy,
            activePane: .left,
            home: home,
            downloads: downloads,
            isDirectory: isDirectory
        )
        let tab = WorkspaceTabRecord(descriptor: descriptor)
        let restored = RestoredWorkspaceSession(
            tabs: [tab],
            activeTabID: tab.id,
            profiles: []
        )
        if let envelope = try? WorkspaceSessionEnvelope(
            tabs: restored.tabs,
            activeTabID: restored.activeTabID,
            profiles: restored.profiles
        ) {
            _ = save(envelope)
        }
        return restored
    }

    private static func restore(
        _ envelope: WorkspaceSessionEnvelope,
        home: URL,
        downloads: URL,
        isDirectory: (URL) -> Bool
    ) -> RestoredWorkspaceSession {
        guard !envelope.tabs.isEmpty else {
            return defaultSession(
                home: home,
                downloads: downloads,
                profiles: envelope.profiles
            )
        }

        let tabs = envelope.tabs.map { tab in
            WorkspaceTabRecord(
                id: tab.id,
                descriptor: repairedDescriptor(
                    from: tab.descriptor.snapshot,
                    activePane: tab.descriptor.activePane,
                    home: home,
                    downloads: downloads,
                    isDirectory: isDirectory
                )
            )
        }
        let activeTabID = tabs.contains(where: { $0.id == envelope.activeTabID })
            ? envelope.activeTabID
            : tabs[0].id
        return RestoredWorkspaceSession(
            tabs: tabs,
            activeTabID: activeTabID,
            profiles: envelope.profiles
        )
    }

    private static func repairedDescriptor(
        from snapshot: WorkspaceSnapshot,
        activePane: WorkspacePersistedPane,
        home: URL,
        downloads: URL,
        isDirectory: (URL) -> Bool
    ) -> WorkspaceDescriptor {
        let leftPath = validDirectoryPath(snapshot.leftPath, isDirectory: isDirectory)
            ?? absoluteFallbackPath(home)
        let rightPath = validDirectoryPath(snapshot.rightPath, isDirectory: isDirectory)
            ?? absoluteFallbackPath(downloads)
        return validatedDescriptor(
            leftPath: leftPath,
            rightPath: rightPath,
            leftSort: snapshot.leftSort,
            rightSort: snapshot.rightSort,
            splitRatio: snapshot.splitRatio,
            activePane: activePane
        )
    }

    private static func defaultSession(
        home: URL,
        downloads: URL,
        profiles: [WorkspaceProfileRecord] = []
    ) -> RestoredWorkspaceSession {
        let descriptor = validatedDescriptor(
            leftPath: absoluteFallbackPath(home),
            rightPath: absoluteFallbackPath(downloads),
            leftSort: FileSort(),
            rightSort: FileSort(),
            splitRatio: 0.5,
            activePane: .left
        )
        let tab = WorkspaceTabRecord(descriptor: descriptor)
        return RestoredWorkspaceSession(
            tabs: [tab],
            activeTabID: tab.id,
            profiles: profiles
        )
    }

    private static func validDirectoryPath(
        _ path: String,
        isDirectory: (URL) -> Bool
    ) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let url = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
        return isDirectory(url) ? url.path : nil
    }

    private static func absoluteFallbackPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasPrefix("/") ? path : "/"
    }

    private static func validatedDescriptor(
        leftPath: String,
        rightPath: String,
        leftSort: FileSort,
        rightSort: FileSort,
        splitRatio: Double,
        activePane: WorkspacePersistedPane
    ) -> WorkspaceDescriptor {
        do {
            return try WorkspaceDescriptor(
                leftPath: leftPath,
                rightPath: rightPath,
                leftSort: leftSort,
                rightSort: rightSort,
                splitRatio: splitRatio,
                activePane: activePane
            )
        } catch {
            preconditionFailure("Persistence generated an invalid absolute workspace path: \(error)")
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return decoder
    }
}
