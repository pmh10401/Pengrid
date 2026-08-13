import Foundation
import Testing
@testable import BloomFileManager

@Suite("WorkspaceSessionPersistenceTests")
struct WorkspaceSessionPersistenceTests {
    @Test func v2RoundTripPreservesOrderDescriptorsAndActiveTab() throws {
        let fixture = WorkspaceSessionDefaultsFixture()
        defer { fixture.remove() }
        let persistence = WorkspaceSessionPersistence(defaults: fixture.defaults)
        let first = WorkspaceTabRecord(
            id: WorkspaceTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            descriptor: try descriptor(
                left: "/First/Left",
                right: "/First/Right",
                leftSort: FileSort(key: .size, direction: .descending),
                activePane: .right
            )
        )
        let second = WorkspaceTabRecord(
            id: WorkspaceTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
            descriptor: try descriptor(
                left: "/Second/Left",
                right: "/Second/Right",
                rightSort: FileSort(key: .modifiedAt, direction: .descending),
                splitRatio: 0.64
            )
        )
        let releaseProfile = try WorkspaceProfileRecord(
            id: WorkspaceProfileID(rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!),
            name: "Release",
            descriptor: second.descriptor
        )
        let workProfile = try WorkspaceProfileRecord(
            id: WorkspaceProfileID(rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!),
            name: "Work",
            descriptor: first.descriptor
        )
        let archiveProfile = try WorkspaceProfileRecord(
            id: WorkspaceProfileID(rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!),
            name: "Archive",
            descriptor: second.descriptor
        )
        let envelope = try WorkspaceSessionEnvelope(
            tabs: [second, first],
            activeTabID: first.id,
            profiles: [archiveProfile, releaseProfile, workProfile]
        )

        #expect(persistence.save(envelope))
        let loaded = persistence.load()

        #expect(loaded == envelope)
        #expect(loaded?.tabs.map(\.id) == [second.id, first.id])
        #expect(loaded?.activeTabID == first.id)
        #expect(loaded?.profiles.map(\.id) == [archiveProfile.id, releaseProfile.id, workProfile.id])
        #expect(loaded?.profiles.map(\.name) == ["Archive", "Release", "Work"])
    }

    @Test func nonFiniteStoredRatiosDecodeAndReencodeAsCanonicalFiniteValues() throws {
        let fixture = WorkspaceSessionDefaultsFixture()
        defer { fixture.remove() }
        let persistence = WorkspaceSessionPersistence(defaults: fixture.defaults)
        fixture.defaults.set(
            Data(
                #"{"activeTabID":"00000000-0000-0000-0000-000000000001","profiles":[],"tabs":[{"descriptor":{"activePane":"left","leftPath":"/A","leftSort":{"direction":"ascending","key":"name"},"rightPath":"/B","rightSort":{"direction":"ascending","key":"name"},"splitRatio":"NaN"},"id":"00000000-0000-0000-0000-000000000001"},{"descriptor":{"activePane":"right","leftPath":"/C","leftSort":{"direction":"ascending","key":"name"},"rightPath":"/D","rightSort":{"direction":"ascending","key":"name"},"splitRatio":"Infinity"},"id":"00000000-0000-0000-0000-000000000002"},{"descriptor":{"activePane":"left","leftPath":"/E","leftSort":{"direction":"ascending","key":"name"},"rightPath":"/F","rightSort":{"direction":"ascending","key":"name"},"splitRatio":"-Infinity"},"id":"00000000-0000-0000-0000-000000000003"}],"version":2}"#.utf8
            ),
            forKey: WorkspaceSessionPersistence.storageKey
        )

        let loaded = try #require(persistence.load())
        #expect(loaded.tabs.map(\.descriptor.splitRatio) == [0.5, 0.75, 0.25])
        #expect(loaded.tabs.allSatisfy { $0.descriptor.splitRatio.isFinite })
        #expect(persistence.save(loaded))

        let savedData = try #require(
            fixture.defaults.data(forKey: WorkspaceSessionPersistence.storageKey)
        )
        let root = try #require(
            JSONSerialization.jsonObject(with: savedData) as? [String: Any]
        )
        let tabs = try #require(root["tabs"] as? [[String: Any]])
        let ratios = tabs.compactMap { tab -> Double? in
            let descriptor = tab["descriptor"] as? [String: Any]
            return (descriptor?["splitRatio"] as? NSNumber)?.doubleValue
        }
        #expect(ratios == [0.5, 0.75, 0.25])
    }

    @Test func savePersistsARepairedActiveTabID() throws {
        let fixture = WorkspaceSessionDefaultsFixture()
        defer { fixture.remove() }
        let persistence = WorkspaceSessionPersistence(defaults: fixture.defaults)
        let first = WorkspaceTabRecord(
            descriptor: try descriptor(left: "/First/Left", right: "/First/Right")
        )
        let second = WorkspaceTabRecord(
            descriptor: try descriptor(left: "/Second/Left", right: "/Second/Right")
        )
        let unknownID = WorkspaceTabID()
        let envelope = try WorkspaceSessionEnvelope(
            tabs: [first, second],
            activeTabID: unknownID,
            profiles: []
        )
        #expect(envelope.activeTabID == unknownID)

        #expect(persistence.save(envelope))

        #expect(persistence.load()?.activeTabID == first.id)
    }

    @Test func v1MigratesToOneTabWhenV2IsAbsent() throws {
        let fixture = WorkspaceSessionDefaultsFixture()
        defer { fixture.remove() }
        let legacyPersistence = WorkspacePersistence(defaults: fixture.defaults)
        let sessionPersistence = WorkspaceSessionPersistence(defaults: fixture.defaults)
        let legacy = WorkspaceSnapshot(
            leftPath: "/Legacy/Left",
            rightPath: "/missing-right",
            leftSort: FileSort(key: .kind, direction: .descending),
            rightSort: FileSort(key: .size, direction: .ascending),
            splitRatio: 0.68
        )
        legacyPersistence.save(legacy)
        let originalLegacyBytes = fixture.defaults.data(forKey: WorkspacePersistence.storageKey)

        let restored = sessionPersistence.restore(
            legacy: legacyPersistence.load(),
            home: directory("/Home"),
            downloads: directory("/Downloads"),
            isDirectory: { $0.path != "/missing-right" }
        )

        #expect(restored.tabs.count == 1)
        #expect(restored.activeTabID == restored.tabs[0].id)
        #expect(restored.tabs[0].descriptor.leftPath == "/Legacy/Left")
        #expect(restored.tabs[0].descriptor.rightPath == "/Downloads")
        #expect(restored.tabs[0].descriptor.leftSort == legacy.leftSort)
        #expect(restored.tabs[0].descriptor.rightSort == legacy.rightSort)
        #expect(restored.tabs[0].descriptor.splitRatio == 0.68)
        #expect(restored.tabs[0].descriptor.activePane == .left)
        #expect(sessionPersistence.load()?.tabs == restored.tabs)
        #expect(fixture.defaults.data(forKey: WorkspacePersistence.storageKey) == originalLegacyBytes)
    }

    @Test func existingV2WinsWithoutRewritingV1() throws {
        let fixture = WorkspaceSessionDefaultsFixture()
        defer { fixture.remove() }
        let legacyPersistence = WorkspacePersistence(defaults: fixture.defaults)
        let sessionPersistence = WorkspaceSessionPersistence(defaults: fixture.defaults)
        legacyPersistence.save(WorkspaceSnapshot(
            leftPath: "/Legacy/Left",
            rightPath: "/Legacy/Right",
            leftSort: FileSort(),
            rightSort: FileSort(),
            splitRatio: 0.5
        ))
        let legacyBytes = fixture.defaults.data(forKey: WorkspacePersistence.storageKey)
        let v2Tab = WorkspaceTabRecord(
            descriptor: try descriptor(left: "/V2/Left", right: "/V2/Right", activePane: .right)
        )
        let v2 = try WorkspaceSessionEnvelope(
            tabs: [v2Tab],
            activeTabID: v2Tab.id,
            profiles: []
        )
        #expect(sessionPersistence.save(v2))

        let restored = sessionPersistence.restore(
            legacy: legacyPersistence.load(),
            home: directory("/Home"),
            downloads: directory("/Downloads"),
            isDirectory: { _ in true }
        )

        #expect(restored.tabs == [v2Tab])
        #expect(restored.activeTabID == v2Tab.id)
        #expect(fixture.defaults.data(forKey: WorkspacePersistence.storageKey) == legacyBytes)
    }

    @Test func malformedV2FallsBackWithoutDeletingV1() throws {
        let fixture = WorkspaceSessionDefaultsFixture()
        defer { fixture.remove() }
        let legacyPersistence = WorkspacePersistence(defaults: fixture.defaults)
        let sessionPersistence = WorkspaceSessionPersistence(defaults: fixture.defaults)
        legacyPersistence.save(WorkspaceSnapshot(
            leftPath: "/Legacy/Left",
            rightPath: "/Legacy/Right",
            leftSort: FileSort(),
            rightSort: FileSort(),
            splitRatio: 0.5
        ))
        let legacyBytes = fixture.defaults.data(forKey: WorkspacePersistence.storageKey)
        let malformedV2 = Data(#"{"version":2,"tabs":["#.utf8)
        fixture.defaults.set(malformedV2, forKey: WorkspaceSessionPersistence.storageKey)

        let restored = sessionPersistence.restore(
            legacy: legacyPersistence.load(),
            home: directory("/Home"),
            downloads: directory("/Downloads"),
            isDirectory: { _ in true }
        )

        #expect(restored.tabs.count == 1)
        #expect(restored.tabs[0].descriptor.leftPath == "/Home")
        #expect(restored.tabs[0].descriptor.rightPath == "/Downloads")
        #expect(restored.activeTabID == restored.tabs[0].id)
        #expect(restored.profiles.isEmpty)
        #expect(fixture.defaults.data(forKey: WorkspaceSessionPersistence.storageKey) == malformedV2)
        #expect(fixture.defaults.data(forKey: WorkspacePersistence.storageKey) == legacyBytes)
    }

    @Test func restoreRepairsEachInvalidPaneIndependently() throws {
        let fixture = WorkspaceSessionDefaultsFixture()
        defer { fixture.remove() }
        let persistence = WorkspaceSessionPersistence(defaults: fixture.defaults)
        let first = WorkspaceTabRecord(
            descriptor: try descriptor(
                left: "/missing-left",
                right: "/First/Right",
                leftSort: FileSort(key: .size, direction: .descending),
                splitRatio: 0.3,
                activePane: .right
            )
        )
        let second = WorkspaceTabRecord(
            descriptor: try descriptor(
                left: "/Second/Left",
                right: "/missing-right",
                rightSort: FileSort(key: .kind, direction: .descending),
                splitRatio: 0.7
            )
        )
        let envelope = try WorkspaceSessionEnvelope(
            tabs: [first, second],
            activeTabID: second.id,
            profiles: []
        )
        #expect(persistence.save(envelope))
        var probes: [String] = []

        let restored = persistence.restore(
            legacy: nil,
            home: directory("/Home"),
            downloads: directory("/Downloads"),
            isDirectory: { url in
                probes.append(url.path)
                return !url.path.hasPrefix("/missing")
            }
        )

        #expect(probes == ["/missing-left", "/First/Right", "/Second/Left", "/missing-right"])
        #expect(restored.tabs.map(\.id) == [first.id, second.id])
        #expect(restored.tabs[0].descriptor.leftPath == "/Home")
        #expect(restored.tabs[0].descriptor.rightPath == "/First/Right")
        #expect(restored.tabs[0].descriptor.leftSort == first.descriptor.leftSort)
        #expect(restored.tabs[0].descriptor.activePane == .right)
        #expect(restored.tabs[1].descriptor.leftPath == "/Second/Left")
        #expect(restored.tabs[1].descriptor.rightPath == "/Downloads")
        #expect(restored.tabs[1].descriptor.rightSort == second.descriptor.rightSort)
        #expect(restored.activeTabID == second.id)
    }

    @Test func emptyTabsRestoreOneHomeDownloadsTab() throws {
        let fixture = WorkspaceSessionDefaultsFixture()
        defer { fixture.remove() }
        let persistence = WorkspaceSessionPersistence(defaults: fixture.defaults)
        let profile = try WorkspaceProfileRecord(
            name: "Kept Profile",
            descriptor: descriptor(left: "/Profile/Left", right: "/Profile/Right")
        )
        let envelope = try WorkspaceSessionEnvelope(
            tabs: [],
            activeTabID: WorkspaceTabID(),
            profiles: [profile]
        )
        #expect(persistence.save(envelope))

        let restored = persistence.restore(
            legacy: nil,
            home: directory("/Home"),
            downloads: directory("/Downloads"),
            isDirectory: { _ in true }
        )

        #expect(restored.tabs.count == 1)
        #expect(restored.tabs[0].descriptor.leftPath == "/Home")
        #expect(restored.tabs[0].descriptor.rightPath == "/Downloads")
        #expect(restored.tabs[0].descriptor.leftSort == FileSort())
        #expect(restored.tabs[0].descriptor.rightSort == FileSort())
        #expect(restored.tabs[0].descriptor.splitRatio == 0.5)
        #expect(restored.tabs[0].descriptor.activePane == .left)
        #expect(restored.activeTabID == restored.tabs[0].id)
        #expect(restored.profiles == [profile])
    }

    @Test func saveRejectsMutatedDuplicateIDsWithoutReplacingStoredData() throws {
        let fixture = WorkspaceSessionDefaultsFixture()
        defer { fixture.remove() }
        let persistence = WorkspaceSessionPersistence(defaults: fixture.defaults)
        let tab = WorkspaceTabRecord(
            descriptor: try descriptor(left: "/Left", right: "/Right")
        )
        let valid = try WorkspaceSessionEnvelope(
            tabs: [tab],
            activeTabID: tab.id,
            profiles: []
        )
        #expect(persistence.save(valid))
        let validBytes = fixture.defaults.data(forKey: WorkspaceSessionPersistence.storageKey)
        var invalid = valid
        invalid.tabs.append(tab)

        #expect(persistence.save(invalid) == false)
        #expect(fixture.defaults.data(forKey: WorkspaceSessionPersistence.storageKey) == validBytes)
    }

    @Test func saveRejectsCorruptTabAndProfileDescriptorsWithoutReplacingStoredData() throws {
        let fixture = WorkspaceSessionDefaultsFixture()
        defer { fixture.remove() }
        let persistence = WorkspaceSessionPersistence(defaults: fixture.defaults)
        let validDescriptor = try descriptor(left: "/Left", right: "/Right")
        let tab = WorkspaceTabRecord(descriptor: validDescriptor)
        let profile = try WorkspaceProfileRecord(name: "Valid", descriptor: validDescriptor)
        let valid = try WorkspaceSessionEnvelope(
            tabs: [tab],
            activeTabID: tab.id,
            profiles: [profile]
        )
        #expect(persistence.save(valid))
        let validBytes = fixture.defaults.data(forKey: WorkspaceSessionPersistence.storageKey)
        var corruptDescriptor = validDescriptor
        corruptDescriptor.leftPath = "relative/left"

        var corruptTabEnvelope = valid
        corruptTabEnvelope.tabs = [
            WorkspaceTabRecord(id: tab.id, descriptor: corruptDescriptor)
        ]
        #expect(persistence.save(corruptTabEnvelope) == false)
        #expect(fixture.defaults.data(forKey: WorkspaceSessionPersistence.storageKey) == validBytes)

        var corruptProfileEnvelope = valid
        corruptProfileEnvelope.profiles = [
            try WorkspaceProfileRecord(
                id: profile.id,
                name: profile.name,
                descriptor: corruptDescriptor
            )
        ]
        #expect(persistence.save(corruptProfileEnvelope) == false)
        #expect(fixture.defaults.data(forKey: WorkspaceSessionPersistence.storageKey) == validBytes)
    }

    private func descriptor(
        left: String,
        right: String,
        leftSort: FileSort = FileSort(),
        rightSort: FileSort = FileSort(),
        splitRatio: Double = 0.5,
        activePane: WorkspacePersistedPane = .left
    ) throws -> WorkspaceDescriptor {
        try WorkspaceDescriptor(
            leftPath: left,
            rightPath: right,
            leftSort: leftSort,
            rightSort: rightSort,
            splitRatio: splitRatio,
            activePane: activePane
        )
    }

    private func directory(_ path: String) -> URL {
        URL(filePath: path, directoryHint: .isDirectory)
    }
}

private final class WorkspaceSessionDefaultsFixture {
    let name = "BloomFileManagerTests.WorkspaceSession.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
    }

    func remove() {
        defaults.removePersistentDomain(forName: name)
    }
}
