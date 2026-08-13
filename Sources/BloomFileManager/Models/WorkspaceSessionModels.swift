import Foundation

struct WorkspaceTabID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    init() {
        self.init(rawValue: UUID())
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(UUID.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct WorkspaceProfileID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    init() {
        self.init(rawValue: UUID())
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(UUID.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum WorkspacePersistedPane: String, Codable, Equatable, Sendable {
    case left
    case right
}

enum WorkspaceSessionValidationError: Error, Equatable, Sendable {
    case invalidLeftPath(String)
    case invalidRightPath(String)
    case emptyProfileName
    case duplicateTabID(WorkspaceTabID)
    case duplicateProfileID(WorkspaceProfileID)
    case duplicateProfileName(String)
    case unsupportedVersion(Int)
}

struct WorkspaceDescriptor: Codable, Equatable, Sendable {
    var leftPath: String
    var rightPath: String
    var leftSort: FileSort
    var rightSort: FileSort
    var splitRatio: Double
    var activePane: WorkspacePersistedPane

    init(
        leftPath: String,
        rightPath: String,
        leftSort: FileSort,
        rightSort: FileSort,
        splitRatio: Double,
        activePane: WorkspacePersistedPane
    ) throws {
        guard Self.isAbsolutePath(leftPath) else {
            throw WorkspaceSessionValidationError.invalidLeftPath(leftPath)
        }
        guard Self.isAbsolutePath(rightPath) else {
            throw WorkspaceSessionValidationError.invalidRightPath(rightPath)
        }

        self.leftPath = leftPath
        self.rightPath = rightPath
        self.leftSort = leftSort
        self.rightSort = rightSort
        self.splitRatio = WorkspaceSplitRatio.clamped(splitRatio)
        self.activePane = activePane
    }

    init(
        snapshot: WorkspaceSnapshot,
        activePane: WorkspacePersistedPane = .left
    ) throws {
        try self.init(
            leftPath: snapshot.leftPath,
            rightPath: snapshot.rightPath,
            leftSort: snapshot.leftSort,
            rightSort: snapshot.rightSort,
            splitRatio: snapshot.splitRatio,
            activePane: activePane
        )
    }

    var snapshot: WorkspaceSnapshot {
        WorkspaceSnapshot(
            leftPath: leftPath,
            rightPath: rightPath,
            leftSort: leftSort,
            rightSort: rightSort,
            splitRatio: splitRatio
        )
    }

    private static func isAbsolutePath(_ path: String) -> Bool {
        !path.isEmpty && path.hasPrefix("/")
    }

    private enum CodingKeys: String, CodingKey {
        case leftPath
        case rightPath
        case leftSort
        case rightSort
        case splitRatio
        case activePane
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            leftPath: container.decode(String.self, forKey: .leftPath),
            rightPath: container.decode(String.self, forKey: .rightPath),
            leftSort: container.decode(FileSort.self, forKey: .leftSort),
            rightSort: container.decode(FileSort.self, forKey: .rightSort),
            splitRatio: container.decode(Double.self, forKey: .splitRatio),
            activePane: container.decode(WorkspacePersistedPane.self, forKey: .activePane)
        )
    }
}

struct WorkspaceTabRecord: Codable, Equatable, Sendable {
    let id: WorkspaceTabID
    let descriptor: WorkspaceDescriptor

    init(
        id: WorkspaceTabID = WorkspaceTabID(),
        descriptor: WorkspaceDescriptor
    ) {
        self.id = id
        self.descriptor = descriptor
    }
}

struct WorkspaceProfileRecord: Codable, Equatable, Sendable {
    let id: WorkspaceProfileID
    let name: String
    let descriptor: WorkspaceDescriptor

    init(
        id: WorkspaceProfileID = WorkspaceProfileID(),
        name: String,
        descriptor: WorkspaceDescriptor
    ) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw WorkspaceSessionValidationError.emptyProfileName
        }

        self.id = id
        self.name = trimmedName
        self.descriptor = descriptor
    }

    static func normalizedNameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case descriptor
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(WorkspaceProfileID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            descriptor: container.decode(WorkspaceDescriptor.self, forKey: .descriptor)
        )
    }
}

struct WorkspaceSessionEnvelope: Codable, Equatable, Sendable {
    static let schemaVersion = 2

    let version: Int
    var tabs: [WorkspaceTabRecord]
    var activeTabID: WorkspaceTabID
    var profiles: [WorkspaceProfileRecord]

    init(
        version: Int = Self.schemaVersion,
        tabs: [WorkspaceTabRecord],
        activeTabID: WorkspaceTabID,
        profiles: [WorkspaceProfileRecord]
    ) throws {
        guard version == Self.schemaVersion else {
            throw WorkspaceSessionValidationError.unsupportedVersion(version)
        }
        try Self.validateRecordCollections(tabs: tabs, profiles: profiles)

        self.version = version
        self.tabs = tabs
        self.activeTabID = activeTabID
        self.profiles = profiles
    }

    var repairedActiveTabID: WorkspaceTabID {
        tabs.contains(where: { $0.id == activeTabID })
            ? activeTabID
            : tabs.first?.id ?? activeTabID
    }

    func validated() throws -> WorkspaceSessionEnvelope {
        try WorkspaceSessionEnvelope(
            version: version,
            tabs: tabs,
            activeTabID: activeTabID,
            profiles: profiles
        )
    }

    private static func validateRecordCollections(
        tabs: [WorkspaceTabRecord],
        profiles: [WorkspaceProfileRecord]
    ) throws {
        var tabIDs = Set<WorkspaceTabID>()
        for tab in tabs where !tabIDs.insert(tab.id).inserted {
            throw WorkspaceSessionValidationError.duplicateTabID(tab.id)
        }

        var profileIDs = Set<WorkspaceProfileID>()
        var profileNames = Set<String>()
        for profile in profiles {
            guard profileIDs.insert(profile.id).inserted else {
                throw WorkspaceSessionValidationError.duplicateProfileID(profile.id)
            }
            let nameKey = WorkspaceProfileRecord.normalizedNameKey(profile.name)
            guard profileNames.insert(nameKey).inserted else {
                throw WorkspaceSessionValidationError.duplicateProfileName(nameKey)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case tabs
        case activeTabID
        case profiles
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            tabs: container.decode([WorkspaceTabRecord].self, forKey: .tabs),
            activeTabID: container.decode(WorkspaceTabID.self, forKey: .activeTabID),
            profiles: container.decode([WorkspaceProfileRecord].self, forKey: .profiles)
        )
    }
}

struct RestoredWorkspaceSession: Equatable, Sendable {
    let tabs: [WorkspaceTabRecord]
    let activeTabID: WorkspaceTabID
    let profiles: [WorkspaceProfileRecord]
}
