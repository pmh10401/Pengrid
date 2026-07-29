import Foundation
import Observation

enum CloudLocationRemovalError: Error, Equatable {
    case locationNotFound
    case notManualLocation
}

@MainActor @Observable
final class CloudLocationsStore {
    var visibleLocations: [StorageLocation] {
        presentation.visible
    }

    var hiddenLocations: [StorageLocation] {
        presentation.hidden
    }
    private(set) var hasCompletedInitialDiscovery = false

    @ObservationIgnored private let storageURL: URL
    @ObservationIgnored private let discovery: any CloudLocationDiscovering
    @ObservationIgnored private let bookmarking: any CloudLocationBookmarking
    @ObservationIgnored private let accessCoordinator: CloudLocationScopedAccessCoordinator
    @ObservationIgnored private var document: CloudLocationsDocument
    @ObservationIgnored private var rootURLs: [StorageLocationID: URL]
    @ObservationIgnored private var scanGeneration: UInt64 = 0
    @ObservationIgnored private var initialScanTask: Task<Void, any Error>?
    private var presentation: Presentation

    static var defaultStorageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: AppIdentity.bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "cloud-locations.json")
    }

    init(
        storageURL: URL = CloudLocationsStore.defaultStorageURL,
        discovery: any CloudLocationDiscovering = LiveCloudLocationDiscovery(),
        bookmarking: any CloudLocationBookmarking = LiveCloudLocationBookmarking(),
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init()
    ) {
        self.storageURL = storageURL
        self.discovery = discovery
        self.bookmarking = bookmarking
        self.accessCoordinator = accessCoordinator

        let loadedDocument = Self.load(from: storageURL)
        var candidateDocument = loadedDocument
        var candidateRootURLs: [StorageLocationID: URL] = [:]
        let didRefresh = Self.refreshManualLocations(
            in: &candidateDocument,
            rootURLs: &candidateRootURLs,
            bookmarking: bookmarking
        )
        if didRefresh, (try? Self.persist(candidateDocument, to: storageURL)) != nil {
            document = candidateDocument
        } else {
            document = loadedDocument
        }
        rootURLs = candidateRootURLs
        presentation = Self.presentation(for: document, rootURLs: rootURLs)
        updateScopedAccessRoots()
    }

    func scanInitially() async throws {
        if hasCompletedInitialDiscovery {
            return
        }
        if let initialScanTask {
            try await initialScanTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try await self.rescan()
        }
        initialScanTask = task
        try await task.value
    }

    func rescan() async throws {
        scanGeneration &+= 1
        let generation = scanGeneration
        let discovered = await discovery.discover()
        try Task.checkCancellation()
        guard generation == scanGeneration else { return }

        var candidateDocument = document
        var candidateRootURLs = rootURLs

        for index in candidateDocument.records.indices
        where candidateDocument.records[index].isDiscovered {
            candidateDocument.records[index].isAvailable = false
        }

        var mergedKeys: Set<DiscoveredRecordKey> = []
        for location in discovered {
            guard let key = DiscoveredRecordKey(location: location),
                  mergedKeys.insert(key).inserted else {
                continue
            }

            if let index = candidateDocument.records.firstIndex(where: { $0.discoveredKey == key }) {
                candidateDocument.records[index].provider = PersistedProviderKind(location.provider)
                candidateDocument.records[index].displayName = location.displayName
                candidateDocument.records[index].isAvailable = location.isAvailable
            } else {
                candidateDocument.records.append(
                    CloudLocationRecord(
                        id: UUID(),
                        provider: PersistedProviderKind(location.provider),
                        displayName: location.displayName,
                        userDisplayName: nil,
                        rootIdentity: key.rootIdentity,
                        domainIdentifier: key.domainIdentifier,
                        bookmarkData: nil,
                        isHidden: false,
                        isAvailable: location.isAvailable
                    )
                )
            }
            candidateRootURLs[key.locationID] = location.rootURL.standardizedFileURL
        }

        _ = try Self.refreshManualLocationsThrowing(
            in: &candidateDocument,
            rootURLs: &candidateRootURLs,
            bookmarking: bookmarking
        )
        try Task.checkCancellation()
        guard generation == scanGeneration else { return }
        try publish(candidateDocument, rootURLs: candidateRootURLs)
        hasCompletedInitialDiscovery = true
    }

    func addManualLocation(_ url: URL) throws {
        let requestedURL = url.standardizedFileURL
        var bookmarkData = try bookmarking.create(for: requestedURL)
        let resolution = try bookmarking.resolve(bookmarkData)
        let resolvedRootURL = resolution.url
        let resolvedURL = resolvedRootURL.standardizedFileURL
        if resolution.isStale {
            bookmarkData = try bookmarking.create(for: resolvedRootURL)
        }

        guard !containsRoot(resolvedURL) else {
            return
        }

        var candidateDocument = document
        var candidateRootURLs = rootURLs
        let record = CloudLocationRecord(
            id: UUID(),
            provider: PersistedProviderKind(.other("Manual Folder")),
            displayName: Self.displayName(for: resolvedURL),
            userDisplayName: nil,
            rootIdentity: nil,
            domainIdentifier: nil,
            bookmarkData: bookmarkData,
            isHidden: false,
            isAvailable: true
        )
        candidateDocument.records.append(record)
        candidateRootURLs[.manualBookmark(record.id)] = resolvedRootURL
        try publish(candidateDocument, rootURLs: candidateRootURLs)
    }

    func renameLocation(_ id: StorageLocationID, to displayName: String) throws {
        let displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty,
              let index = document.records.firstIndex(where: { $0.locationID == id }),
              document.records[index].userDisplayName != displayName else {
            return
        }

        var candidateDocument = document
        candidateDocument.records[index].userDisplayName = displayName
        try publish(candidateDocument, rootURLs: rootURLs)
    }

    func hide(_ id: StorageLocationID) throws {
        try setHidden(true, for: id)
    }

    func unhide(_ id: StorageLocationID) throws {
        try setHidden(false, for: id)
    }

    func removeManualLocation(_ id: StorageLocationID) throws {
        guard let index = document.records.firstIndex(where: { $0.locationID == id }) else {
            throw CloudLocationRemovalError.locationNotFound
        }
        guard document.records[index].bookmarkData != nil else {
            throw CloudLocationRemovalError.notManualLocation
        }

        var candidateDocument = document
        candidateDocument.records.remove(at: index)
        var candidateRootURLs = rootURLs
        candidateRootURLs.removeValue(forKey: id)
        try publish(candidateDocument, rootURLs: candidateRootURLs)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) throws {
        let visibleRecords = document.records.filter { record in
            guard !record.isHidden, let locationID = record.locationID else {
                return false
            }
            return rootURLs[locationID] != nil
        }
        guard !source.isEmpty,
              source.allSatisfy(visibleRecords.indices.contains),
              (0...visibleRecords.count).contains(destination) else {
            return
        }

        let movedRecords = source.map { visibleRecords[$0] }
        var reorderedVisible = visibleRecords.enumerated()
            .filter { !source.contains($0.offset) }
            .map { $0.element }
        let removedBeforeDestination = source.filter { $0 < destination }.count
        let insertionIndex = destination - removedBeforeDestination
        guard reorderedVisible.indices.contains(insertionIndex)
                || insertionIndex == reorderedVisible.endIndex else {
            return
        }
        reorderedVisible.insert(contentsOf: movedRecords, at: insertionIndex)
        guard reorderedVisible.map({ $0.id }) != visibleRecords.map({ $0.id }) else {
            return
        }

        var reorderedIterator = reorderedVisible.makeIterator()
        var candidateDocument = document
        for index in candidateDocument.records.indices {
            guard !candidateDocument.records[index].isHidden,
                  let locationID = candidateDocument.records[index].locationID,
                  rootURLs[locationID] != nil else {
                continue
            }
            if let next = reorderedIterator.next() {
                candidateDocument.records[index] = next
            }
        }
        try publish(candidateDocument, rootURLs: rootURLs)
    }

    private func containsRoot(_ requestedURL: URL) -> Bool {
        let requestedURL = requestedURL.standardizedFileURL
        if rootURLs.values.contains(where: { $0.standardizedFileURL == requestedURL }) {
            return true
        }
        return document.records.contains { record in
            guard let bookmarkData = record.bookmarkData,
                  let resolution = try? bookmarking.resolve(bookmarkData) else {
                return false
            }
            return resolution.url.standardizedFileURL == requestedURL
        }
    }

    private func setHidden(_ isHidden: Bool, for id: StorageLocationID) throws {
        guard let index = document.records.firstIndex(where: { $0.locationID == id }),
              document.records[index].isHidden != isHidden else {
            return
        }
        var candidateDocument = document
        candidateDocument.records[index].isHidden = isHidden
        try publish(candidateDocument, rootURLs: rootURLs)
    }

    private func publish(
        _ candidateDocument: CloudLocationsDocument,
        rootURLs candidateRootURLs: [StorageLocationID: URL]
    ) throws {
        try Self.persist(candidateDocument, to: storageURL)
        document = candidateDocument
        rootURLs = candidateRootURLs
        presentation = Self.presentation(for: candidateDocument, rootURLs: candidateRootURLs)
        updateScopedAccessRoots()
    }

    private func updateScopedAccessRoots() {
        let roots = document.records.compactMap { record -> URL? in
            guard record.bookmarkData != nil,
                  let locationID = record.locationID else {
                return nil
            }
            return rootURLs[locationID]
        }
        accessCoordinator.replaceManualRoots(roots)
    }

    private static func load(from storageURL: URL) -> CloudLocationsDocument {
        guard let data = try? Data(contentsOf: storageURL),
              let document = try? JSONDecoder().decode(CloudLocationsDocument.self, from: data),
              document.version == CloudLocationsDocument.currentVersion else {
            return CloudLocationsDocument()
        }
        return document
    }

    private static func persist(_ document: CloudLocationsDocument, to storageURL: URL) throws {
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(document).write(to: storageURL, options: .atomic)
    }

    private static func refreshManualLocations(
        in document: inout CloudLocationsDocument,
        rootURLs: inout [StorageLocationID: URL],
        bookmarking: any CloudLocationBookmarking
    ) -> Bool {
        (try? refreshManualLocationsThrowing(
            in: &document,
            rootURLs: &rootURLs,
            bookmarking: bookmarking
        )) ?? false
    }

    @discardableResult
    private static func refreshManualLocationsThrowing(
        in document: inout CloudLocationsDocument,
        rootURLs: inout [StorageLocationID: URL],
        bookmarking: any CloudLocationBookmarking
    ) throws -> Bool {
        var didRefresh = false
        for index in document.records.indices {
            guard let bookmarkData = document.records[index].bookmarkData else {
                continue
            }
            do {
                let resolution = try bookmarking.resolve(bookmarkData)
                let resolvedRootURL = resolution.url
                let resolvedURL = resolvedRootURL.standardizedFileURL
                rootURLs[.manualBookmark(document.records[index].id)] = resolvedRootURL
                if document.records[index].displayName != displayName(for: resolvedURL) {
                    document.records[index].displayName = displayName(for: resolvedURL)
                    didRefresh = true
                }
                if !document.records[index].isAvailable {
                    document.records[index].isAvailable = true
                    didRefresh = true
                }
                if resolution.isStale {
                    document.records[index].bookmarkData = try bookmarking.create(for: resolvedRootURL)
                    didRefresh = true
                }
            } catch {
                if document.records[index].isAvailable {
                    document.records[index].isAvailable = false
                    didRefresh = true
                }
            }
        }
        return didRefresh
    }

    private static func presentation(
        for document: CloudLocationsDocument,
        rootURLs: [StorageLocationID: URL]
    ) -> Presentation {
        var visible: [StorageLocation] = []
        var hidden: [StorageLocation] = []
        for record in document.records {
            guard let locationID = record.locationID,
                  let rootURL = rootURLs[locationID] else {
                continue
            }
            let location = StorageLocation(
                id: locationID,
                provider: record.provider.cloudProvider,
                displayName: record.userDisplayName ?? record.displayName,
                rootURL: rootURL,
                isAvailable: record.isAvailable,
                capabilities: [.browse, .materialize, .localFileOperations],
                source: record.isDiscovered ? .discovered : .manualBookmark
            )
            if record.isHidden {
                hidden.append(location)
            } else {
                visible.append(location)
            }
        }
        return Presentation(visible: visible, hidden: hidden)
    }

    private static func displayName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? "Folder" : name
    }
}

@MainActor
extension CloudLocationsStore {
    func intersectsKnownLocation(_ url: URL) -> Bool {
        let candidateComponents = url.standardizedFileURL.pathComponents
        return rootURLs.values.contains { knownRoot in
            let knownComponents = knownRoot.standardizedFileURL.pathComponents
            return candidateComponents.starts(with: knownComponents)
                || knownComponents.starts(with: candidateComponents)
        }
    }
}

private struct Presentation {
    var visible: [StorageLocation]
    var hidden: [StorageLocation]
}

private struct CloudLocationsDocument: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    var records: [CloudLocationRecord]

    init(version: Int = currentVersion, records: [CloudLocationRecord] = []) {
        self.version = version
        self.records = records
    }
}

private struct CloudLocationRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var provider: PersistedProviderKind
    var displayName: String
    var userDisplayName: String?
    var rootIdentity: Data?
    var domainIdentifier: String?
    var bookmarkData: Data?
    var isHidden: Bool
    var isAvailable: Bool

    var isDiscovered: Bool {
        rootIdentity != nil && bookmarkData == nil
    }

    var discoveredKey: DiscoveredRecordKey? {
        guard let rootIdentity else { return nil }
        return DiscoveredRecordKey(
            domainIdentifier: Self.normalizedDomainIdentifier(domainIdentifier),
            rootIdentity: rootIdentity
        )
    }

    var locationID: StorageLocationID? {
        if let discoveredKey {
            return discoveredKey.locationID
        }
        if bookmarkData != nil {
            return .manualBookmark(id)
        }
        return nil
    }

    private static func normalizedDomainIdentifier(_ identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty else { return nil }
        return identifier
    }
}

private struct DiscoveredRecordKey: Hashable {
    let domainIdentifier: String?
    let rootIdentity: Data

    init(domainIdentifier: String?, rootIdentity: Data) {
        self.domainIdentifier = domainIdentifier
        self.rootIdentity = rootIdentity
    }

    init?(location: StorageLocation) {
        guard case let .fileProvider(domainIdentifier, rootIdentity) = location.id else {
            return nil
        }
        self.domainIdentifier = domainIdentifier.isEmpty ? nil : domainIdentifier
        self.rootIdentity = rootIdentity
    }

    var locationID: StorageLocationID {
        .fileProvider(domainIdentifier: domainIdentifier ?? "", rootIdentity: rootIdentity)
    }
}

private struct PersistedProviderKind: Codable, Equatable {
    private enum Kind: String, Codable {
        case iCloudDrive
        case googleDrive
        case oneDrive
        case dropbox
        case other
    }

    private let kind: Kind
    private let otherName: String?

    init(_ provider: CloudProviderKind) {
        switch provider {
        case .iCloudDrive:
            kind = .iCloudDrive
            otherName = nil
        case .googleDrive:
            kind = .googleDrive
            otherName = nil
        case .oneDrive:
            kind = .oneDrive
            otherName = nil
        case .dropbox:
            kind = .dropbox
            otherName = nil
        case let .other(name):
            kind = .other
            otherName = name
        }
    }

    var cloudProvider: CloudProviderKind {
        switch kind {
        case .iCloudDrive: .iCloudDrive
        case .googleDrive: .googleDrive
        case .oneDrive: .oneDrive
        case .dropbox: .dropbox
        case .other: .other(otherName ?? "Cloud")
        }
    }
}
