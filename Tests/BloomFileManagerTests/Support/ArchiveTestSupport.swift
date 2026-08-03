import Darwin
import Foundation
@testable import BloomFileManager

func archiveTestIdentity(for url: URL) -> FileIdentity {
    if let entryIdentifier = archiveTestNodeIdentifier(for: url, followsSymbolicLink: false) {
        let resolvedIdentifier = archiveTestNodeIdentifier(
            for: url,
            followsSymbolicLink: true
        ) ?? entryIdentifier
        return FileIdentity(
            entryIdentifier: entryIdentifier,
            resolvedIdentifier: resolvedIdentifier
        )
    }
    let token = "recording:\(url.standardizedFileURL.path)"
    return FileIdentity(entryIdentifier: token, resolvedIdentifier: token)
}

private func archiveTestNodeIdentifier(
    for url: URL,
    followsSymbolicLink: Bool
) -> String? {
    var information = stat()
    let inspectedURL = followsSymbolicLink ? url.resolvingSymlinksInPath() : url
    let status = inspectedURL.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return Darwin.lstat(path, &information)
    }
    guard status == 0 else { return nil }
    return "\(UInt64(information.st_dev)):\(UInt64(information.st_ino))"
}

func identifiedArchiveTestSources(_ urls: [URL]) -> [IdentifiedFileRequest] {
    urls.map { url in
        IdentifiedFileRequest(
            url: url,
            identity: archiveTestIdentity(for: url)
        )
    }
}

extension ArchiveRequest {
    init(
        kind: ArchiveOperationKind,
        verifiedSources: [URL],
        finalDestination: URL,
        progressDisplayName: String? = nil,
        format: ArchiveFormat = .zip
    ) {
        self.init(
            kind: kind,
            verifiedSources: identifiedArchiveTestSources(verifiedSources),
            finalDestination: finalDestination,
            destinationParentIdentity: archiveTestIdentity(
                for: finalDestination.deletingLastPathComponent()
            ),
            progressDisplayName: progressDisplayName,
            format: format
        )
    }
}

extension LiveArchiveCommandRunner {
    @discardableResult
    func run(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        sources: [URL],
        destination: URL
    ) async throws -> FileIdentity {
        try await run(
            kind: kind,
            format: format,
            sources: identifiedArchiveTestSources(sources),
            destination: destination,
            destinationParentIdentity: archiveTestIdentity(
                for: destination.deletingLastPathComponent()
            )
        )
    }

    @discardableResult
    func run(
        kind: ArchiveOperationKind,
        format: ArchiveFormat,
        sources: [URL],
        destination: URL,
        progress: @escaping ArchiveCommandProgressHandler
    ) async throws -> FileIdentity {
        try await run(
            kind: kind,
            format: format,
            sources: identifiedArchiveTestSources(sources),
            destination: destination,
            destinationParentIdentity: archiveTestIdentity(
                for: destination.deletingLastPathComponent()
            ),
            progress: progress
        )
    }
}
