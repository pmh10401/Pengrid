import Foundation
import Testing
@testable import BloomFileManager

@Suite("WorkspaceSessionModelsTests")
struct WorkspaceSessionModelsTests {
    @Test func profileNameValidationIsTrimmedAndComparisonUnique() throws {
        let profile = try WorkspaceProfileRecord(
            name: "  Work  ",
            descriptor: WorkspaceDescriptor.fixture(
                left: "/Work/Source",
                right: "/Work/Build"
            )
        )

        #expect(profile.name == "Work")
        #expect(
            WorkspaceProfileRecord.normalizedNameKey("Wórk")
                == WorkspaceProfileRecord.normalizedNameKey("work")
        )
    }

    @Test func descriptorValidatesAbsolutePathsAndClampsRatios() throws {
        #expect(throws: WorkspaceSessionValidationError.invalidLeftPath("relative/left")) {
            try WorkspaceDescriptor(
                leftPath: "relative/left",
                rightPath: "/right",
                leftSort: FileSort(),
                rightSort: FileSort(),
                splitRatio: 0.5,
                activePane: .left
            )
        }
        #expect(throws: WorkspaceSessionValidationError.invalidRightPath("relative/right")) {
            try WorkspaceDescriptor(
                leftPath: "/left",
                rightPath: "relative/right",
                leftSort: FileSort(),
                rightSort: FileSort(),
                splitRatio: 0.5,
                activePane: .right
            )
        }

        let low = try WorkspaceDescriptor.fixture(left: "/left", right: "/right", splitRatio: 0.1)
        let high = try WorkspaceDescriptor.fixture(left: "/left", right: "/right", splitRatio: 0.9)
        let notANumber = try WorkspaceDescriptor.fixture(left: "/left", right: "/right", splitRatio: .nan)

        #expect(low.splitRatio == 0.25)
        #expect(high.splitRatio == 0.75)
        #expect(notANumber.splitRatio == 0.5)
    }

    @Test func profileNameRejectsWhitespaceOnlyInput() throws {
        #expect(throws: WorkspaceSessionValidationError.emptyProfileName) {
            try WorkspaceProfileRecord(
                name: " \n\t ",
                descriptor: WorkspaceDescriptor.fixture(left: "/left", right: "/right")
            )
        }
    }

    @Test func envelopeRepairsUnknownActiveIDToFirstTab() throws {
        let first = WorkspaceTabRecord(
            descriptor: try WorkspaceDescriptor.fixture(left: "/A", right: "/B")
        )
        let envelope = try WorkspaceSessionEnvelope(
            tabs: [first],
            activeTabID: WorkspaceTabID(),
            profiles: []
        )

        #expect(envelope.repairedActiveTabID == first.id)
    }

    @Test func envelopePreservesOrderAndRejectsDuplicateRecordIDs() throws {
        let first = WorkspaceTabRecord(
            descriptor: try WorkspaceDescriptor.fixture(left: "/A", right: "/B")
        )
        let second = WorkspaceTabRecord(
            descriptor: try WorkspaceDescriptor.fixture(left: "/C", right: "/D")
        )
        let profile = try WorkspaceProfileRecord(
            name: "Primary",
            descriptor: first.descriptor
        )
        let envelope = try WorkspaceSessionEnvelope(
            tabs: [second, first],
            activeTabID: first.id,
            profiles: [profile]
        )

        #expect(envelope.tabs.map(\.id) == [second.id, first.id])
        #expect(envelope.profiles.map(\.id) == [profile.id])
        #expect(throws: WorkspaceSessionValidationError.duplicateTabID(first.id)) {
            try WorkspaceSessionEnvelope(
                tabs: [first, first],
                activeTabID: first.id,
                profiles: []
            )
        }
        #expect(throws: WorkspaceSessionValidationError.duplicateProfileID(profile.id)) {
            try WorkspaceSessionEnvelope(
                tabs: [first],
                activeTabID: first.id,
                profiles: [profile, profile]
            )
        }
    }

    @Test func envelopeRejectsNormalizedDuplicateProfileNames() throws {
        let descriptor = try WorkspaceDescriptor.fixture(left: "/left", right: "/right")
        let first = try WorkspaceProfileRecord(name: "Wórk", descriptor: descriptor)
        let second = try WorkspaceProfileRecord(name: " work ", descriptor: descriptor)
        let tab = WorkspaceTabRecord(descriptor: descriptor)

        #expect(throws: WorkspaceSessionValidationError.duplicateProfileName("work")) {
            try WorkspaceSessionEnvelope(
                tabs: [tab],
                activeTabID: tab.id,
                profiles: [first, second]
            )
        }
    }

    @Test func envelopeRejectsUnsupportedSchemaVersion() throws {
        let descriptor = try WorkspaceDescriptor.fixture(left: "/left", right: "/right")
        let tab = WorkspaceTabRecord(descriptor: descriptor)

        #expect(throws: WorkspaceSessionValidationError.unsupportedVersion(1)) {
            try WorkspaceSessionEnvelope(
                version: 1,
                tabs: [tab],
                activeTabID: tab.id,
                profiles: []
            )
        }
    }
}

private extension WorkspaceDescriptor {
    static func fixture(
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
}
