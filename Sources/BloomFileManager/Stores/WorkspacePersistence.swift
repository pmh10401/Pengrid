import Foundation

struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    var leftPath: String
    var rightPath: String
    var leftSort: FileSort
    var rightSort: FileSort
    var splitRatio: Double
}

struct RestoredWorkspace: Equatable, Sendable {
    var leftURL: URL
    var rightURL: URL
    var leftSort: FileSort
    var rightSort: FileSort
    var splitRatio: Double
}

final class WorkspacePersistence {
    static let storageKey = "workspace.snapshot.v1"
    static let savedSearchesStorageKey = "smartSearches.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> WorkspaceSnapshot? {
        guard let data = defaults.data(forKey: Self.storageKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return try? decoder.decode(WorkspaceSnapshot.self, from: data)
    }

    func save(_ snapshot: WorkspaceSnapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    func loadSavedSearches() -> [SmartSearchRecord] {
        guard let data = defaults.data(forKey: Self.savedSearchesStorageKey) else { return [] }
        return (try? JSONDecoder().decode([SmartSearchRecord].self, from: data)) ?? []
    }

    func saveSavedSearches(_ searches: [SmartSearchRecord]) {
        guard let data = try? JSONEncoder().encode(searches) else { return }
        defaults.set(data, forKey: Self.savedSearchesStorageKey)
    }

    var smartSearchPersistence: any SmartSearchPersisting {
        WorkspaceSmartSearchPersistence(defaults: defaults)
    }

    func restore(
        home: URL,
        downloads: URL,
        isDirectory: (URL) -> Bool = WorkspacePersistence.isExistingDirectory
    ) -> RestoredWorkspace {
        guard let snapshot = load() else {
            return Self.defaults(home: home, downloads: downloads)
        }

        let leftURL = Self.validDirectoryURL(path: snapshot.leftPath, isDirectory: isDirectory) ?? home
        let rightURL = Self.validDirectoryURL(path: snapshot.rightPath, isDirectory: isDirectory) ?? downloads
        return RestoredWorkspace(
            leftURL: leftURL,
            rightURL: rightURL,
            leftSort: snapshot.leftSort,
            rightSort: snapshot.rightSort,
            splitRatio: WorkspaceSplitRatio.clamped(snapshot.splitRatio)
        )
    }

    private static func defaults(home: URL, downloads: URL) -> RestoredWorkspace {
        RestoredWorkspace(
            leftURL: home,
            rightURL: downloads,
            leftSort: FileSort(),
            rightSort: FileSort(),
            splitRatio: 0.5
        )
    }

    private static func validDirectoryURL(
        path: String,
        isDirectory: (URL) -> Bool
    ) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        let url = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
        return isDirectory(url) ? url : nil
    }

    private static func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isReadableFile(atPath: url.path)
        else { return false }
        return true
    }
}

private final class WorkspaceSmartSearchPersistence: SmartSearchPersisting, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() -> Data? {
        defaults.data(forKey: WorkspacePersistence.savedSearchesStorageKey)
    }

    func save(_ data: Data) {
        defaults.set(data, forKey: WorkspacePersistence.savedSearchesStorageKey)
    }
}
