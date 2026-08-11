import AppKit
import Foundation
import UniformTypeIdentifiers

struct OpenWithFileKindKey: Sendable, Hashable {
    let contentTypeIdentifier: String
    let filenameExtension: String
    let isPackage: Bool

    init(
        contentTypeIdentifier: String,
        filenameExtension: String,
        isPackage: Bool
    ) {
        self.contentTypeIdentifier = contentTypeIdentifier
        self.filenameExtension = filenameExtension
        self.isPackage = isPackage
    }

    init(item: FileItem) {
        let filenameExtension = item.url.pathExtension.lowercased()
        self.init(
            contentTypeIdentifier: UTType(filenameExtension: filenameExtension)?.identifier
                ?? UTType.data.identifier,
            filenameExtension: filenameExtension,
            isPackage: item.isPackage
        )
    }
}

@MainActor
protocol OpenWithApplicationProviding {
    func cachedApplications(for item: FileItem) -> [OpenWithApplication]?
    func requestApplications(for item: FileItem)
}

@MainActor
final class OpenWithApplicationProvider: OpenWithApplicationProviding {
    typealias WorkspaceQuery = @Sendable (URL) async -> [URL]
    typealias DisplayNameProvider = @Sendable (URL) -> String
    typealias KeyResolver = @Sendable (FileItem) -> OpenWithFileKindKey

    private let workspaceQuery: WorkspaceQuery
    private let displayName: DisplayNameProvider
    private let currentApplicationURL: URL?
    private let keyResolver: KeyResolver
    private var cachedByKind: [OpenWithFileKindKey: [OpenWithApplication]] = [:]
    private var requestedKinds: Set<OpenWithFileKindKey> = []

    init(
        workspaceQuery: @escaping WorkspaceQuery = { url in
            NSWorkspace.shared.urlsForApplications(toOpen: url)
        },
        displayName: @escaping DisplayNameProvider = { url in
            FileManager.default.displayName(atPath: url.path)
        },
        currentApplicationURL: URL? = Bundle.main.bundleURL,
        keyResolver: @escaping KeyResolver = { OpenWithFileKindKey(item: $0) }
    ) {
        self.workspaceQuery = workspaceQuery
        self.displayName = displayName
        self.currentApplicationURL = currentApplicationURL?.standardizedFileURL
        self.keyResolver = keyResolver
    }

    func cachedApplications(for item: FileItem) -> [OpenWithApplication]? {
        cachedByKind[keyResolver(item)]
    }

    func requestApplications(for item: FileItem) {
        let key = keyResolver(item)
        guard cachedByKind[key] == nil, requestedKinds.insert(key).inserted else { return }

        let itemURL = item.url.standardizedFileURL
        let workspaceQuery = self.workspaceQuery
        let displayName = self.displayName
        let currentApplicationURL = self.currentApplicationURL
        Task { [weak self] in
            let discoveredURLs = await workspaceQuery(itemURL)
            guard !Task.isCancelled else { return }
            let applications = Self.applications(
                from: discoveredURLs,
                excluding: currentApplicationURL,
                displayName: displayName
            )
            self?.publish(applications, for: key)
        }
    }

    func invalidateApplications(for item: FileItem) {
        invalidateApplications(for: keyResolver(item))
    }

    func invalidateAllApplications() {
        cachedByKind.removeAll()
        requestedKinds.removeAll()
    }

    private func invalidateApplications(for key: OpenWithFileKindKey) {
        cachedByKind.removeValue(forKey: key)
        requestedKinds.remove(key)
    }

    private func publish(
        _ applications: [OpenWithApplication],
        for key: OpenWithFileKindKey
    ) {
        requestedKinds.remove(key)
        cachedByKind[key] = applications
    }

    private static func applications(
        from urls: [URL],
        excluding currentApplicationURL: URL?,
        displayName: DisplayNameProvider
    ) -> [OpenWithApplication] {
        let normalizedCurrentApplicationURL = currentApplicationURL?.standardizedFileURL
        var seenURLs: Set<URL> = []
        let applications = urls.compactMap { url -> OpenWithApplication? in
            let applicationURL = url.standardizedFileURL
            guard applicationURL != normalizedCurrentApplicationURL,
                  seenURLs.insert(applicationURL).inserted
            else { return nil }
            return OpenWithApplication(
                applicationURL: applicationURL,
                displayName: displayName(applicationURL)
            )
        }
        return applications.sorted {
            let nameComparison = $0.displayName.localizedStandardCompare($1.displayName)
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }
            return $0.applicationURL.standardizedFileURL.absoluteString
                < $1.applicationURL.standardizedFileURL.absoluteString
        }
    }
}
