import Foundation
import Testing
@testable import BloomFileManager

@MainActor
struct OpenWithApplicationProviderTests {
    @Test func applicationsUseTheExactKindKeyAndRemainCachedUntilInvalidated() async {
        let document = item(at: URL(filePath: "/documents/report.txt"))
        let sameKind = item(at: URL(filePath: "/other/copy.txt"))
        let package = FileItem(
            url: URL(filePath: "/documents/report.txt", directoryHint: .isDirectory),
            name: "report.txt",
            isDirectory: true,
            isPackage: true,
            modifiedAt: nil,
            byteSize: nil,
            typeDescription: "Package"
        )
        let query = OpenWithWorkspaceQueryRecorder(results: [[
            URL(filePath: "/Applications/TextEdit.app", directoryHint: .isDirectory)
        ]])
        let provider = OpenWithApplicationProvider(
            workspaceQuery: { url in await query.applications(for: url) },
            displayName: { _ in "TextEdit" },
            currentApplicationURL: nil,
            keyResolver: { item in
                OpenWithFileKindKey(
                    contentTypeIdentifier: "public.plain-text",
                    filenameExtension: item.url.pathExtension,
                    isPackage: item.isPackage
                )
            }
        )

        #expect(provider.cachedApplications(for: document) == nil)
        provider.requestApplications(for: document)
        let first = await applications(from: provider, for: document)
        #expect(first.map(\.displayName) == ["TextEdit"])
        #expect(provider.cachedApplications(for: sameKind) == first)
        #expect(provider.cachedApplications(for: package) == nil)
        #expect(await query.urls == [document.url])

        provider.invalidateApplications(for: document)
        #expect(provider.cachedApplications(for: document) == nil)
        provider.requestApplications(for: document)
        _ = await applications(from: provider, for: document)
        #expect(await query.urls == [document.url, document.url])
    }

    @Test func applicationsAreDeduplicatedExcludeTheRunningAppAndSortByLocalizedNameThenURL() async {
        let document = item(at: URL(filePath: "/documents/report.txt"))
        let current = URL(filePath: "/Applications/Pengrid.app", directoryHint: .isDirectory)
        let alphaSecond = URL(filePath: "/Applications/Alpha 2.app", directoryHint: .isDirectory)
        let alphaFirst = URL(filePath: "/Applications/Alpha 1.app", directoryHint: .isDirectory)
        let beta = URL(filePath: "/Applications/Beta.app", directoryHint: .isDirectory)
        let provider = OpenWithApplicationProvider(
            workspaceQuery: { _ in [beta, current, alphaSecond, beta, alphaFirst] },
            displayName: { url in
                switch url.standardizedFileURL {
                case alphaFirst, alphaSecond: "Alpha"
                case beta: "Beta"
                default: "Pengrid"
                }
            },
            currentApplicationURL: current,
            keyResolver: { _ in
                OpenWithFileKindKey(
                    contentTypeIdentifier: "public.plain-text",
                    filenameExtension: "txt",
                    isPackage: false
                )
            }
        )

        provider.requestApplications(for: document)
        let applications = await applications(from: provider, for: document)

        #expect(applications == [
            OpenWithApplication(applicationURL: alphaFirst, displayName: "Alpha"),
            OpenWithApplication(applicationURL: alphaSecond, displayName: "Alpha"),
            OpenWithApplication(applicationURL: beta, displayName: "Beta")
        ])
    }
}

private actor OpenWithWorkspaceQueryRecorder {
    private let results: [[URL]]
    private var callCount = 0
    private(set) var urls: [URL] = []

    init(results: [[URL]]) {
        self.results = results
    }

    func applications(for url: URL) -> [URL] {
        urls.append(url)
        defer { callCount += 1 }
        return results[min(callCount, results.count - 1)]
    }
}

@MainActor
private func applications(
    from provider: OpenWithApplicationProvider,
    for item: FileItem
) async -> [OpenWithApplication] {
    for _ in 0..<100 {
        if let applications = provider.cachedApplications(for: item) {
            return applications
        }
        await Task.yield()
    }
    Issue.record("Open With discovery did not publish its cache entry.")
    return []
}

private func item(at url: URL) -> FileItem {
    FileItem(
        url: url,
        name: url.lastPathComponent,
        isDirectory: false,
        isPackage: false,
        modifiedAt: nil,
        byteSize: 1,
        typeDescription: "Text"
    )
}
