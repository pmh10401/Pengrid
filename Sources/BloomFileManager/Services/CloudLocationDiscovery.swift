import FileProvider
import Foundation

struct CloudLocationCandidate: Sendable {
    let url: URL
    let canonicalURL: URL
    let rootIdentity: Data
    let domainIdentifier: String?
    let systemDisplayName: String
}

protocol CloudLocationFileSystem: Sendable {
    func candidates() async -> [CloudLocationCandidate]
}

protocol CloudLocationDiscovering: Sendable {
    func discover() async -> [StorageLocation]
}

struct LiveCloudLocationFileSystem: CloudLocationFileSystem {
    func candidates() async -> [CloudLocationCandidate] {
        let fileManager = FileManager.default
        let cloudStorageDirectory = fileManager.homeDirectoryForCurrentUser
            .appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .fileResourceIdentifierKey,
            .canonicalPathKey,
            .nameKey
        ]

        guard let urls = try? fileManager.contentsOfDirectory(
            at: cloudStorageDirectory,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            return []
        }

        var candidates: [CloudLocationCandidate] = []
        for url in urls {
            guard fileManager.isReadableFile(atPath: url.path),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isDirectory == true else {
                continue
            }

            let canonicalURL = canonicalURL(for: url, values: values)
            guard let canonicalValues = try? canonicalURL.resourceValues(forKeys: [.fileResourceIdentifierKey]),
                  let identifier = canonicalValues.fileResourceIdentifier,
                  let rootIdentity = CloudLocationRootIdentityEncoder.encode(identifier) else {
                continue
            }

            candidates.append(CloudLocationCandidate(
                url: url.standardizedFileURL,
                canonicalURL: canonicalURL,
                rootIdentity: rootIdentity,
                domainIdentifier: await domainIdentifier(for: url),
                systemDisplayName: values.name ?? url.lastPathComponent
            ))
        }
        return candidates
    }

    private func canonicalURL(for url: URL, values: URLResourceValues) -> URL {
        guard let canonicalPath = values.canonicalPath else {
            return url.standardizedFileURL
        }
        return URL(fileURLWithPath: canonicalPath, isDirectory: true).standardizedFileURL
    }

    private func domainIdentifier(for url: URL) async -> String? {
        await withCheckedContinuation { continuation in
            NSFileProviderManager.getIdentifierForUserVisibleFile(at: url) { _, domainIdentifier, error in
                continuation.resume(returning: error == nil ? domainIdentifier?.rawValue : nil)
            }
        }
    }
}

struct LiveCloudLocationDiscovery: CloudLocationDiscovering {
    private let fileSystem: any CloudLocationFileSystem

    init(fileSystem: any CloudLocationFileSystem = LiveCloudLocationFileSystem()) {
        self.fileSystem = fileSystem
    }

    func discover() async -> [StorageLocation] {
        var discoveredIdentities: Set<Data> = []
        let uniqueCandidates = await fileSystem.candidates()
            .sorted(by: candidateComesFirst)
            .filter { discoveredIdentities.insert($0.rootIdentity).inserted }

        return uniqueCandidates.map(location(for:))
    }

    private func location(for candidate: CloudLocationCandidate) -> StorageLocation {
        StorageLocation(
            id: .fileProvider(
                domainIdentifier: candidate.domainIdentifier ?? "",
                rootIdentity: candidate.rootIdentity
            ),
            provider: provider(for: candidate),
            displayName: candidate.systemDisplayName,
            rootURL: candidate.canonicalURL,
            isAvailable: true,
            capabilities: [.browse, .materialize, .localFileOperations],
            source: .discovered
        )
    }

    private func provider(for candidate: CloudLocationCandidate) -> CloudProviderKind {
        if let domainIdentifier = candidate.domainIdentifier,
           let provider = knownProvider(for: domainIdentifier) {
            return provider
        }
        return knownProvider(for: candidate.systemDisplayName) ?? .other(candidate.systemDisplayName)
    }

    private func knownProvider(for evidence: String) -> CloudProviderKind? {
        let evidence = evidence.lowercased()
        if evidence.contains("google") { return .googleDrive }
        if evidence.contains("onedrive") || evidence.contains("microsoft") { return .oneDrive }
        if evidence.contains("dropbox") { return .dropbox }
        return nil
    }

    private func candidateComesFirst(
        _ left: CloudLocationCandidate,
        _ right: CloudLocationCandidate
    ) -> Bool {
        let nameOrder = left.systemDisplayName.localizedStandardCompare(right.systemDisplayName)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        return left.rootIdentity.lexicographicallyPrecedes(right.rootIdentity)
    }
}

enum CloudLocationRootIdentityEncoder {
    static func encode(_ identifier: Any) -> Data? {
        let propertyList = [identifier]
        guard PropertyListSerialization.propertyList(propertyList, isValidFor: .binary) else {
            return nil
        }
        return try? PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .binary,
            options: 0
        )
    }
}
