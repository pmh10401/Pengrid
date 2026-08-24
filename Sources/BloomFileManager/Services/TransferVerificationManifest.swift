import Darwin
import Foundation

struct TransferVerificationLimits: Sendable, Equatable {
    static let production = Self(maxDescendants: 250_000, maxDepth: 256)

    let maxDescendants: Int
    let maxDepth: Int
}

enum TransferVerificationManifestError: Error, Equatable {
    case changed
    case structureMismatch
    case unsupportedItem
    case unsupportedName
    case readFailed
    case scopeTooLarge
    case cancelled
}

struct TransferVerificationBudget: Sendable, Equatable {
    private let limits: TransferVerificationLimits
    private(set) var descendantCount = 0
    private(set) var regularFileCount = 0
    private(set) var logicalByteCount: Int64 = 0

    init(limits: TransferVerificationLimits) {
        self.limits = limits
    }

    mutating func includeRoot(regularFileSize: Int64?) throws {
        guard limits.maxDepth >= 0, limits.maxDescendants >= 0 else {
            throw TransferVerificationManifestError.scopeTooLarge
        }
        try includeRegularFile(regularFileSize)
    }

    mutating func includeDescendant(
        atDepth depth: Int,
        regularFileSize: Int64?
    ) throws {
        var candidate = self
        try candidate.reserveDescendants(1, atDepth: depth)
        try candidate.includeRegularFile(regularFileSize)
        self = candidate
    }

    func maximumChildren(atParentDepth parentDepth: Int) -> Int {
        guard parentDepth >= 0,
              parentDepth < limits.maxDepth,
              descendantCount < limits.maxDescendants
        else {
            return 0
        }
        return limits.maxDescendants - descendantCount
    }

    mutating func reserveDescendants(_ count: Int, atDepth depth: Int) throws {
        guard count >= 0 else { throw TransferVerificationManifestError.scopeTooLarge }
        if count == 0 { return }
        guard depth > 0, depth <= limits.maxDepth else {
            throw TransferVerificationManifestError.scopeTooLarge
        }
        let (newCount, overflow) = descendantCount.addingReportingOverflow(count)
        guard !overflow, newCount <= limits.maxDescendants else {
            throw TransferVerificationManifestError.scopeTooLarge
        }
        descendantCount = newCount
    }

    mutating func includeRegularFile(_ size: Int64?) throws {
        guard let size else { return }
        guard size >= 0 else { throw TransferVerificationManifestError.readFailed }
        let (newCount, countOverflow) = regularFileCount.addingReportingOverflow(1)
        let (newBytes, byteOverflow) = logicalByteCount.addingReportingOverflow(size)
        guard !countOverflow, !byteOverflow else {
            throw TransferVerificationManifestError.scopeTooLarge
        }
        regularFileCount = newCount
        logicalByteCount = newBytes
    }
}

enum TransferVerificationComparisonKeyBuilder {
    static func key(
        for components: [String],
        policy: FilenameComparisonPolicy
    ) -> [String] {
        components.map(policy.key(for:))
    }

    static func requireUnique(
        _ components: [[String]],
        policy: FilenameComparisonPolicy
    ) throws {
        var keys = Set<[String]>()
        for path in components {
            try insertUnique(key(for: path, policy: policy), into: &keys)
        }
    }

    static func insertUnique<Key: Hashable>(
        _ key: Key,
        into keys: inout Set<Key>
    ) throws {
        guard keys.insert(key).inserted else {
            throw TransferVerificationManifestError.structureMismatch
        }
    }
}

enum TransferVerificationFilenameDecoder {
    static func decode(_ bytes: [UInt8]) throws -> String {
        guard !bytes.isEmpty,
              !bytes.contains(0),
              let name = String(bytes: bytes, encoding: .utf8),
              Array(name.utf8) == bytes
        else {
            throw TransferVerificationManifestError.unsupportedName
        }
        return name
    }
}

#if DEBUG
enum TransferVerificationDescriptorRole: Sendable, Equatable {
    case rootParent
    case rootDirectory
    case enumerationDuplicate
    case readerParentDuplicate
    case readerRootDuplicate
    case readerComponentDirectory
    case readerCandidate
    case reader
    case traversalParentDuplicate
    case traversalDirectory
    case validationFile
}

struct TransferVerificationDescriptorEvent: Sendable, Equatable {
    enum Action: Sendable, Equatable {
        case acquired
        case closed
    }

    let leaseID: UInt64
    let descriptor: Int32
    let action: Action
    let role: TransferVerificationDescriptorRole
}
#endif

private final class TransferVerificationDescriptorLifecycle: @unchecked Sendable {
    #if DEBUG
    private let lock = NSLock()
    private var nextLeaseID: UInt64 = 0
    private let onEvent: (@Sendable (TransferVerificationDescriptorEvent) -> Void)?

    init(onEvent: (@Sendable (TransferVerificationDescriptorEvent) -> Void)?) {
        self.onEvent = onEvent
    }

    func own(
        _ descriptor: Int32,
        role: TransferVerificationDescriptorRole,
        duplicateDescriptor: @escaping TransferVerificationOwnedDescriptor.DuplicateDescriptor
            = transferVerificationDuplicateDescriptor
    ) -> TransferVerificationOwnedDescriptor {
        let leaseID = lock.withLock {
            nextLeaseID &+= 1
            return nextLeaseID
        }
        onEvent?(
            TransferVerificationDescriptorEvent(
                leaseID: leaseID,
                descriptor: descriptor,
                action: .acquired,
                role: role
            )
        )
        let onEvent = onEvent
        return TransferVerificationOwnedDescriptor(
            descriptor: descriptor,
            closeDescriptor: { descriptor in
                _ = Darwin.close(descriptor)
                onEvent?(
                    TransferVerificationDescriptorEvent(
                        leaseID: leaseID,
                        descriptor: descriptor,
                        action: .closed,
                        role: role
                    )
                )
            },
            closeDirectory: { directory, descriptor in
                _ = Darwin.closedir(directory)
                onEvent?(
                    TransferVerificationDescriptorEvent(
                        leaseID: leaseID,
                        descriptor: descriptor,
                        action: .closed,
                        role: role
                    )
                )
            },
            duplicateDescriptor: duplicateDescriptor
        )
    }
    #else
    init() {}

    func own(
        _ descriptor: Int32,
        duplicateDescriptor: @escaping TransferVerificationOwnedDescriptor.DuplicateDescriptor
            = transferVerificationDuplicateDescriptor
    ) -> TransferVerificationOwnedDescriptor {
        TransferVerificationOwnedDescriptor(
            descriptor: descriptor,
            duplicateDescriptor: duplicateDescriptor
        )
    }
    #endif
}

private final class TransferVerificationOwnedDirectoryStream: @unchecked Sendable {
    typealias CloseDirectory = @Sendable (UnsafeMutablePointer<DIR>, Int32) -> Void

    private let lock = NSLock()
    private let descriptor: Int32
    private let closeDirectory: CloseDirectory
    private var directory: UnsafeMutablePointer<DIR>?

    init(
        directory: UnsafeMutablePointer<DIR>,
        descriptor: Int32,
        closeDirectory: @escaping CloseDirectory
    ) {
        self.directory = directory
        self.descriptor = descriptor
        self.closeDirectory = closeDirectory
    }

    func withDirectory<T>(_ body: (UnsafeMutablePointer<DIR>) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let directory else {
            throw TransferVerificationManifestError.readFailed
        }
        return try body(directory)
    }

    func close() {
        let directoryToClose: UnsafeMutablePointer<DIR>?
        lock.lock()
        directoryToClose = directory
        directory = nil
        lock.unlock()
        if let directoryToClose {
            closeDirectory(directoryToClose, descriptor)
        }
    }

    deinit {
        close()
    }
}

final class TransferVerificationOwnedDescriptor: @unchecked Sendable {
    typealias CloseDescriptor = @Sendable (Int32) -> Void
    typealias CloseDirectory = @Sendable (UnsafeMutablePointer<DIR>, Int32) -> Void
    typealias DuplicateDescriptor = @Sendable (Int32) -> Int32

    private let lock = NSLock()
    private let closeDescriptor: CloseDescriptor
    private let closeDirectory: CloseDirectory
    private let duplicateDescriptor: DuplicateDescriptor
    private var descriptor: Int32?

    init(
        descriptor: Int32,
        closeDescriptor: @escaping CloseDescriptor = { _ = Darwin.close($0) },
        closeDirectory: @escaping CloseDirectory = { directory, _ in
            _ = Darwin.closedir(directory)
        },
        duplicateDescriptor: @escaping DuplicateDescriptor = transferVerificationDuplicateDescriptor
    ) {
        self.descriptor = descriptor
        self.closeDescriptor = closeDescriptor
        self.closeDirectory = closeDirectory
        self.duplicateDescriptor = duplicateDescriptor
    }

    func duplicate() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard let descriptor else {
            throw TransferVerificationManifestError.changed
        }
        let duplicate = duplicateDescriptor(descriptor)
        guard duplicate >= 0 else {
            throw TransferVerificationManifestError.readFailed
        }
        return duplicate
    }

    func withDescriptor<T>(_ body: (Int32) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let descriptor else {
            throw TransferVerificationManifestError.changed
        }
        return try body(descriptor)
    }

    fileprivate func transferToDirectoryStream() throws -> TransferVerificationOwnedDirectoryStream {
        lock.lock()
        defer { lock.unlock() }
        guard let descriptor else {
            throw TransferVerificationManifestError.readFailed
        }
        guard let directory = Darwin.fdopendir(descriptor) else {
            throw TransferVerificationManifestError.readFailed
        }
        self.descriptor = nil
        return TransferVerificationOwnedDirectoryStream(
            directory: directory,
            descriptor: descriptor,
            closeDirectory: closeDirectory
        )
    }

    func close() {
        let descriptorToClose: Int32?
        lock.lock()
        descriptorToClose = descriptor
        descriptor = nil
        lock.unlock()
        if let descriptorToClose {
            closeDescriptor(descriptorToClose)
        }
    }

    deinit {
        close()
    }
}

fileprivate enum TransferVerificationEntryKind: UInt8, Sendable, Equatable {
    case regularFile
    case directory
    case symbolicLink
}

fileprivate struct TransferVerificationNodeFingerprint: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64

    init(_ information: stat) {
        device = UInt64(information.st_dev)
        inode = UInt64(information.st_ino)
        mode = UInt32(information.st_mode)
        size = Int64(information.st_size)
        modificationSeconds = Int64(information.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(information.st_mtimespec.tv_nsec)
        changeSeconds = Int64(information.st_ctimespec.tv_sec)
        changeNanoseconds = Int64(information.st_ctimespec.tv_nsec)
    }

    #if DEBUG
    init(
        device: UInt64,
        inode: UInt64,
        mode: UInt32,
        size: Int64,
        modificationSeconds: Int64 = 0,
        modificationNanoseconds: Int64 = 0,
        changeSeconds: Int64 = 0,
        changeNanoseconds: Int64 = 0
    ) {
        self.device = device
        self.inode = inode
        self.mode = mode
        self.size = size
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
        self.changeSeconds = changeSeconds
        self.changeNanoseconds = changeNanoseconds
    }
    #endif

    var identityToken: String {
        "\(device):\(inode)"
    }
}

fileprivate struct TransferVerificationPathNode: Sendable, Equatable {
    let parentIndex: Int?
    let depth: Int
    let rawName: [UInt8]
    let displayName: String
    let comparisonComponent: String
    let kind: TransferVerificationEntryKind
    let fingerprint: TransferVerificationNodeFingerprint
    let symbolicLinkPayload: [UInt8]?
    var childIndices: [Int]
}

struct TransferVerificationPathStorageMetrics: Sendable, Equatable {
    let nodeCount: Int
    let retainedPathComponentCount: Int
    let rawComponentByteCount: Int
    let displayComponentUTF8ByteCount: Int
    let comparisonComponentUTF8ByteCount: Int
}

fileprivate final class TransferVerificationPathStorage: @unchecked Sendable {
    let nodes: [TransferVerificationPathNode]
    let metrics: TransferVerificationPathStorageMetrics

    init(
        nodes: [TransferVerificationPathNode],
        metrics: TransferVerificationPathStorageMetrics
    ) {
        self.nodes = nodes
        self.metrics = metrics
    }

    func comparisonKey(for nodeIndex: Int) -> [String] {
        var result: [String] = []
        var cursor = nodeIndex
        while cursor != 0 {
            let node = nodes[cursor]
            result.append(node.comparisonComponent)
            guard let parentIndex = node.parentIndex else { break }
            cursor = parentIndex
        }
        result.reverse()
        return result
    }

    func directoryAncestors(ofRegularFileAt nodeIndex: Int) -> [Int] {
        var result: [Int] = []
        var cursor = nodes[nodeIndex].parentIndex
        while let index = cursor, index != 0 {
            result.append(index)
            cursor = nodes[index].parentIndex
        }
        result.reverse()
        return result
    }
}

private struct TransferVerificationPathArena {
    private(set) var nodes: [TransferVerificationPathNode]
    private var childComparisonKeys: [Set<String>]
    private var rawComponentByteCount = 0
    private var displayComponentUTF8ByteCount = 0
    private var comparisonComponentUTF8ByteCount = 0

    init(
        rootKind: TransferVerificationEntryKind,
        rootFingerprint: TransferVerificationNodeFingerprint,
        symbolicLinkPayload: [UInt8]?
    ) {
        nodes = [
            TransferVerificationPathNode(
                parentIndex: nil,
                depth: 0,
                rawName: [],
                displayName: "",
                comparisonComponent: "",
                kind: rootKind,
                fingerprint: rootFingerprint,
                symbolicLinkPayload: symbolicLinkPayload,
                childIndices: []
            )
        ]
        childComparisonKeys = [[]]
    }

    func displayComponents(to nodeIndex: Int) -> [String] {
        var result: [String] = []
        var cursor = nodeIndex
        while cursor != 0 {
            let node = nodes[cursor]
            result.append(node.displayName)
            guard let parentIndex = node.parentIndex else { break }
            cursor = parentIndex
        }
        result.reverse()
        return result
    }

    func requireAvailable(
        comparisonComponent: String,
        under parentIndex: Int
    ) throws {
        guard !childComparisonKeys[parentIndex].contains(comparisonComponent) else {
            throw TransferVerificationManifestError.structureMismatch
        }
    }

    mutating func appendChild(
        parentIndex: Int,
        rawName: [UInt8],
        displayName: String,
        comparisonComponent: String,
        kind: TransferVerificationEntryKind,
        fingerprint: TransferVerificationNodeFingerprint,
        symbolicLinkPayload: [UInt8]?
    ) throws -> Int {
        try TransferVerificationComparisonKeyBuilder.insertUnique(
            comparisonComponent,
            into: &childComparisonKeys[parentIndex]
        )
        let nodeIndex = nodes.count
        let depth = nodes[parentIndex].depth + 1
        nodes.append(
            TransferVerificationPathNode(
                parentIndex: parentIndex,
                depth: depth,
                rawName: rawName,
                displayName: displayName,
                comparisonComponent: comparisonComponent,
                kind: kind,
                fingerprint: fingerprint,
                symbolicLinkPayload: symbolicLinkPayload,
                childIndices: []
            )
        )
        childComparisonKeys.append([])
        nodes[parentIndex].childIndices.append(nodeIndex)
        rawComponentByteCount += rawName.count
        displayComponentUTF8ByteCount += displayName.utf8.count
        comparisonComponentUTF8ByteCount += comparisonComponent.utf8.count
        return nodeIndex
    }

    func freeze() -> TransferVerificationPathStorage {
        TransferVerificationPathStorage(
            nodes: nodes,
            metrics: TransferVerificationPathStorageMetrics(
                nodeCount: nodes.count,
                retainedPathComponentCount: max(0, nodes.count - 1),
                rawComponentByteCount: rawComponentByteCount,
                displayComponentUTF8ByteCount: displayComponentUTF8ByteCount,
                comparisonComponentUTF8ByteCount: comparisonComponentUTF8ByteCount
            )
        )
    }
}

struct TransferVerificationRootAuthorityToken: Hashable, Sendable {
    private let rawValue: UUID

    init() {
        rawValue = UUID()
    }
}

fileprivate final class TransferVerificationRootAuthority: @unchecked Sendable {
    private let stateLock = NSLock()
    private var isClosed = false
    private let parentDescriptor: TransferVerificationOwnedDescriptor
    private let directoryRootDescriptor: TransferVerificationOwnedDescriptor?
    let authorityToken = TransferVerificationRootAuthorityToken()
    let rawRootName: [UInt8]
    let rootFingerprint: TransferVerificationNodeFingerprint
    let rootKind: TransferVerificationEntryKind
    private let descriptorLifecycle: TransferVerificationDescriptorLifecycle
    #if DEBUG
    private let afterReaderDirectoryOpen: (@Sendable ([String]) throws -> Void)?
    #endif

    #if DEBUG
    init(
        parentDescriptor: TransferVerificationOwnedDescriptor,
        directoryRootDescriptor: TransferVerificationOwnedDescriptor?,
        rawRootName: [UInt8],
        rootFingerprint: TransferVerificationNodeFingerprint,
        rootKind: TransferVerificationEntryKind,
        descriptorLifecycle: TransferVerificationDescriptorLifecycle,
        afterReaderDirectoryOpen: (@Sendable ([String]) throws -> Void)?
    ) {
        self.parentDescriptor = parentDescriptor
        self.directoryRootDescriptor = directoryRootDescriptor
        self.rawRootName = rawRootName
        self.rootFingerprint = rootFingerprint
        self.rootKind = rootKind
        self.descriptorLifecycle = descriptorLifecycle
        self.afterReaderDirectoryOpen = afterReaderDirectoryOpen
    }
    #else
    init(
        parentDescriptor: TransferVerificationOwnedDescriptor,
        directoryRootDescriptor: TransferVerificationOwnedDescriptor?,
        rawRootName: [UInt8],
        rootFingerprint: TransferVerificationNodeFingerprint,
        rootKind: TransferVerificationEntryKind,
        descriptorLifecycle: TransferVerificationDescriptorLifecycle
    ) {
        self.parentDescriptor = parentDescriptor
        self.directoryRootDescriptor = directoryRootDescriptor
        self.rawRootName = rawRootName
        self.rootFingerprint = rootFingerprint
        self.rootKind = rootKind
        self.descriptorLifecycle = descriptorLifecycle
    }
    #endif

    func close() {
        stateLock.lock()
        guard !isClosed else {
            stateLock.unlock()
            return
        }
        isClosed = true
        stateLock.unlock()
        directoryRootDescriptor?.close()
        parentDescriptor.close()
    }

    func openReaderDescriptor(
        pathStorage: TransferVerificationPathStorage,
        nodeIndex: Int
    ) throws -> TransferVerificationOwnedDescriptor {
        try transferVerificationCheckTaskCancellation()
        guard pathStorage.nodes.indices.contains(nodeIndex) else {
            throw TransferVerificationManifestError.changed
        }
        let fileNode = pathStorage.nodes[nodeIndex]
        guard fileNode.kind == .regularFile else {
            throw TransferVerificationManifestError.changed
        }
        #if DEBUG
        let anchors = try duplicateAnchors(
            parentRole: .readerParentDuplicate,
            rootRole: .readerRootDuplicate
        )
        #else
        let anchors = try duplicateAnchors()
        #endif
        let parentDuplicate = anchors.parent
        var rootDuplicate = anchors.root
        defer {
            parentDuplicate.close()
            rootDuplicate?.close()
        }
        try transferVerificationCheckTaskCancellation()
        let parentValue = try parentDuplicate.withDescriptor { $0 }
        try requireRootNamespace(in: parentValue)

        if nodeIndex == 0 {
            guard rootKind == .regularFile else {
                throw TransferVerificationManifestError.changed
            }
            return try Self.openVerifiedRegularFile(
                in: parentValue,
                name: rawRootName,
                expected: fileNode.fingerprint,
                descriptorLifecycle: descriptorLifecycle
            )
        }

        guard rootKind == .directory, let openedRoot = rootDuplicate else {
            throw TransferVerificationManifestError.changed
        }
        rootDuplicate = nil
        var currentDirectory = openedRoot
        do {
            try requireOpenedRoot(
                currentDirectory,
                parentDescriptor: parentValue
            )
            var openedComponents: [String] = []
            for directoryIndex in pathStorage.directoryAncestors(
                ofRegularFileAt: nodeIndex
            ) {
                try transferVerificationCheckTaskCancellation()
                let step = pathStorage.nodes[directoryIndex]
                guard step.kind == .directory else {
                    throw TransferVerificationManifestError.changed
                }
                let currentValue = try currentDirectory.withDescriptor { $0 }
                let inspected = try transferVerificationStatAt(
                    currentValue,
                    name: step.rawName,
                    flags: AT_SYMLINK_NOFOLLOW,
                    changeMeansChanged: true
                )
                guard TransferVerificationNodeFingerprint(inspected) == step.fingerprint else {
                    throw TransferVerificationManifestError.changed
                }
                let nextValue = try transferVerificationOpenAt(
                    currentValue,
                    name: step.rawName,
                    flags: transferVerificationDirectoryOpenFlags,
                    failureContext: .postInspectionOpen
                )
                #if DEBUG
                let nextDirectory = descriptorLifecycle.own(
                    nextValue,
                    role: .readerComponentDirectory
                )
                #else
                let nextDirectory = descriptorLifecycle.own(nextValue)
                #endif
                do {
                    let opened = try transferVerificationFstat(nextValue)
                    guard TransferVerificationNodeFingerprint(opened) == step.fingerprint else {
                        throw TransferVerificationManifestError.changed
                    }
                    openedComponents.append(step.displayName)
                    #if DEBUG
                    do {
                        try afterReaderDirectoryOpen?(openedComponents)
                    } catch let error as TransferVerificationManifestError {
                        throw error
                    } catch {
                        throw TransferVerificationManifestError.readFailed
                    }
                    #endif
                    let finalNamespace = try transferVerificationStatAt(
                        currentValue,
                        name: step.rawName,
                        flags: AT_SYMLINK_NOFOLLOW,
                        changeMeansChanged: true
                    )
                    guard TransferVerificationNodeFingerprint(finalNamespace)
                        == step.fingerprint
                    else {
                        throw TransferVerificationManifestError.changed
                    }
                } catch {
                    nextDirectory.close()
                    throw error
                }
                currentDirectory.close()
                currentDirectory = nextDirectory
            }
            try transferVerificationCheckTaskCancellation()
            let currentValue = try currentDirectory.withDescriptor { $0 }
            let reader = try Self.openVerifiedRegularFile(
                in: currentValue,
                name: fileNode.rawName,
                expected: fileNode.fingerprint,
                descriptorLifecycle: descriptorLifecycle
            )
            do {
                try requireRootNamespace(in: parentValue)
            } catch {
                reader.close()
                throw error
            }
            currentDirectory.close()
            return reader
        } catch {
            currentDirectory.close()
            throw error
        }
    }

    func openTraversalDirectory(
        nodes: [TransferVerificationPathNode],
        nodeIndex: Int,
        cancellation: TransferVerificationCancellationState
    ) throws -> TransferVerificationOwnedDescriptor {
        try cancellation.check()
        guard nodes.indices.contains(nodeIndex),
              nodes[nodeIndex].kind == .directory,
              rootKind == .directory
        else {
            throw TransferVerificationManifestError.changed
        }
        #if DEBUG
        let anchors = try duplicateAnchors(
            parentRole: .traversalParentDuplicate,
            rootRole: .traversalDirectory,
            usesInjectedDuplicator: false
        )
        #else
        let anchors = try duplicateAnchors(usesInjectedDuplicator: false)
        #endif
        let parentDuplicate = anchors.parent
        var rootDuplicate = anchors.root
        defer {
            parentDuplicate.close()
            rootDuplicate?.close()
        }
        let parentValue = try parentDuplicate.withDescriptor { $0 }
        try requireRootNamespace(in: parentValue)
        guard let openedRoot = rootDuplicate else {
            throw TransferVerificationManifestError.changed
        }
        rootDuplicate = nil
        var currentDirectory = openedRoot
        do {
            try requireOpenedRoot(
                currentDirectory,
                parentDescriptor: parentValue
            )
            for directoryIndex in try Self.directoryPath(
                in: nodes,
                to: nodeIndex
            ) {
                try cancellation.check()
                let step = nodes[directoryIndex]
                let currentValue = try currentDirectory.withDescriptor { $0 }
                let inspected = try transferVerificationStatAt(
                    currentValue,
                    name: step.rawName,
                    flags: AT_SYMLINK_NOFOLLOW,
                    changeMeansChanged: true
                )
                guard TransferVerificationNodeFingerprint(inspected) == step.fingerprint else {
                    throw TransferVerificationManifestError.changed
                }
                let nextValue = try transferVerificationOpenAt(
                    currentValue,
                    name: step.rawName,
                    flags: transferVerificationDirectoryOpenFlags,
                    failureContext: .postInspectionOpen
                )
                #if DEBUG
                let nextDirectory = descriptorLifecycle.own(
                    nextValue,
                    role: .traversalDirectory
                )
                #else
                let nextDirectory = descriptorLifecycle.own(nextValue)
                #endif
                do {
                    let opened = try transferVerificationFstat(nextValue)
                    guard TransferVerificationNodeFingerprint(opened) == step.fingerprint else {
                        throw TransferVerificationManifestError.changed
                    }
                    let finalNamespace = try transferVerificationStatAt(
                        currentValue,
                        name: step.rawName,
                        flags: AT_SYMLINK_NOFOLLOW,
                        changeMeansChanged: true
                    )
                    guard TransferVerificationNodeFingerprint(finalNamespace)
                        == step.fingerprint
                    else {
                        throw TransferVerificationManifestError.changed
                    }
                } catch {
                    nextDirectory.close()
                    throw error
                }
                currentDirectory.close()
                currentDirectory = nextDirectory
            }
            try cancellation.check()
            let currentValue = try currentDirectory.withDescriptor { $0 }
            let currentInformation = try transferVerificationFstat(currentValue)
            guard TransferVerificationNodeFingerprint(currentInformation)
                == nodes[nodeIndex].fingerprint
            else {
                throw TransferVerificationManifestError.changed
            }
            try requireRootNamespace(in: parentValue)
            return currentDirectory
        } catch {
            currentDirectory.close()
            throw error
        }
    }

    #if DEBUG
    private func duplicateAnchors(
        parentRole: TransferVerificationDescriptorRole,
        rootRole: TransferVerificationDescriptorRole,
        usesInjectedDuplicator: Bool = true
    ) throws -> (
        parent: TransferVerificationOwnedDescriptor,
        root: TransferVerificationOwnedDescriptor?
    ) {
        var parentDuplicate: TransferVerificationOwnedDescriptor?
        var rootDuplicate: TransferVerificationOwnedDescriptor?
        stateLock.lock()
        guard !isClosed else {
            stateLock.unlock()
            throw TransferVerificationManifestError.changed
        }
        do {
            parentDuplicate = descriptorLifecycle.own(
                try duplicate(
                    parentDescriptor,
                    usesInjectedDuplicator: usesInjectedDuplicator
                ),
                role: parentRole
            )
            if let directoryRootDescriptor {
                rootDuplicate = descriptorLifecycle.own(
                    try duplicate(
                        directoryRootDescriptor,
                        usesInjectedDuplicator: usesInjectedDuplicator
                    ),
                    role: rootRole
                )
            }
            stateLock.unlock()
        } catch {
            stateLock.unlock()
            rootDuplicate?.close()
            parentDuplicate?.close()
            throw error
        }
        guard let parentDuplicate else {
            rootDuplicate?.close()
            throw TransferVerificationManifestError.readFailed
        }
        return (parentDuplicate, rootDuplicate)
    }
    #else
    private func duplicateAnchors(
        usesInjectedDuplicator: Bool = true
    ) throws -> (
        parent: TransferVerificationOwnedDescriptor,
        root: TransferVerificationOwnedDescriptor?
    ) {
        var parentDuplicate: TransferVerificationOwnedDescriptor?
        var rootDuplicate: TransferVerificationOwnedDescriptor?
        stateLock.lock()
        guard !isClosed else {
            stateLock.unlock()
            throw TransferVerificationManifestError.changed
        }
        do {
            parentDuplicate = descriptorLifecycle.own(
                try duplicate(
                    parentDescriptor,
                    usesInjectedDuplicator: usesInjectedDuplicator
                )
            )
            if let directoryRootDescriptor {
                rootDuplicate = descriptorLifecycle.own(
                    try duplicate(
                        directoryRootDescriptor,
                        usesInjectedDuplicator: usesInjectedDuplicator
                    )
                )
            }
            stateLock.unlock()
        } catch {
            stateLock.unlock()
            rootDuplicate?.close()
            parentDuplicate?.close()
            throw error
        }
        guard let parentDuplicate else {
            rootDuplicate?.close()
            throw TransferVerificationManifestError.readFailed
        }
        return (parentDuplicate, rootDuplicate)
    }
    #endif

    private func duplicate(
        _ owner: TransferVerificationOwnedDescriptor,
        usesInjectedDuplicator: Bool
    ) throws -> Int32 {
        if usesInjectedDuplicator {
            return try owner.duplicate()
        }
        return try owner.withDescriptor { descriptor in
            let duplicate = transferVerificationDuplicateDescriptor(descriptor)
            guard duplicate >= 0 else {
                throw TransferVerificationManifestError.readFailed
            }
            return duplicate
        }
    }

    private func requireRootNamespace(in parentDescriptor: Int32) throws {
        let information = try transferVerificationStatAt(
            parentDescriptor,
            name: rawRootName,
            flags: AT_SYMLINK_NOFOLLOW,
            changeMeansChanged: true
        )
        guard TransferVerificationNodeFingerprint(information) == rootFingerprint else {
            throw TransferVerificationManifestError.changed
        }
    }

    private func requireOpenedRoot(
        _ openedRoot: TransferVerificationOwnedDescriptor,
        parentDescriptor: Int32
    ) throws {
        let rootValue = try openedRoot.withDescriptor { $0 }
        let openedInformation = try transferVerificationFstat(rootValue)
        guard TransferVerificationNodeFingerprint(openedInformation) == rootFingerprint else {
            throw TransferVerificationManifestError.changed
        }
        try requireRootNamespace(in: parentDescriptor)
    }

    private static func directoryPath(
        in nodes: [TransferVerificationPathNode],
        to nodeIndex: Int
    ) throws -> [Int] {
        var result: [Int] = []
        var cursor = nodeIndex
        while cursor != 0 {
            guard nodes.indices.contains(cursor),
                  nodes[cursor].kind == .directory,
                  let parentIndex = nodes[cursor].parentIndex
            else {
                throw TransferVerificationManifestError.changed
            }
            result.append(cursor)
            cursor = parentIndex
        }
        result.reverse()
        return result
    }

    private static func openVerifiedRegularFile(
        in parentDescriptor: Int32,
        name: [UInt8],
        expected: TransferVerificationNodeFingerprint,
        descriptorLifecycle: TransferVerificationDescriptorLifecycle
    ) throws -> TransferVerificationOwnedDescriptor {
        let inspected = try transferVerificationStatAt(
            parentDescriptor,
            name: name,
            flags: AT_SYMLINK_NOFOLLOW,
            changeMeansChanged: true
        )
        guard TransferVerificationNodeFingerprint(inspected) == expected else {
            throw TransferVerificationManifestError.changed
        }
        let openedDescriptorValue = try transferVerificationOpenAt(
            parentDescriptor,
            name: name,
            flags: transferVerificationRegularOpenFlags,
            failureContext: .postInspectionOpen
        )
        #if DEBUG
        let openedDescriptor = descriptorLifecycle.own(
            openedDescriptorValue,
            role: .readerCandidate
        )
        #else
        let openedDescriptor = descriptorLifecycle.own(openedDescriptorValue)
        #endif
        defer { openedDescriptor.close() }
        let opened = try transferVerificationFstat(openedDescriptorValue)
        guard TransferVerificationNodeFingerprint(opened) == expected,
              try transferVerificationKind(of: opened) == .regularFile
        else {
            throw TransferVerificationManifestError.changed
        }
        let finalNamespace = try transferVerificationStatAt(
            parentDescriptor,
            name: name,
            flags: AT_SYMLINK_NOFOLLOW,
            changeMeansChanged: true
        )
        guard TransferVerificationNodeFingerprint(finalNamespace) == expected else {
            throw TransferVerificationManifestError.changed
        }
        let reader = Darwin.fcntl(openedDescriptorValue, F_DUPFD_CLOEXEC, 0)
        guard reader >= 0 else { throw TransferVerificationManifestError.readFailed }
        #if DEBUG
        return descriptorLifecycle.own(reader, role: .reader)
        #else
        return descriptorLifecycle.own(reader)
        #endif
    }

    deinit {
        close()
    }
}

fileprivate final class TransferVerificationRegularFileHandle: @unchecked Sendable {
    let authority: TransferVerificationRootAuthority
    let pathStorage: TransferVerificationPathStorage
    let nodeIndex: Int

    init(
        authority: TransferVerificationRootAuthority,
        pathStorage: TransferVerificationPathStorage,
        nodeIndex: Int
    ) {
        self.authority = authority
        self.pathStorage = pathStorage
        self.nodeIndex = nodeIndex
    }

    var comparisonKey: [String] {
        pathStorage.comparisonKey(for: nodeIndex)
    }

    func openReaderDescriptor() throws -> TransferVerificationOwnedDescriptor {
        try authority.openReaderDescriptor(
            pathStorage: pathStorage,
            nodeIndex: nodeIndex
        )
    }
}

struct TransferVerificationRegularFileEntry: @unchecked Sendable {
    var comparisonKey: [String] { handle.comparisonKey }
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let logicalByteCount: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
    private let handle: TransferVerificationRegularFileHandle

    fileprivate init(
        fingerprint: TransferVerificationNodeFingerprint,
        handle: TransferVerificationRegularFileHandle
    ) {
        device = fingerprint.device
        inode = fingerprint.inode
        mode = fingerprint.mode
        logicalByteCount = fingerprint.size
        modificationSeconds = fingerprint.modificationSeconds
        modificationNanoseconds = fingerprint.modificationNanoseconds
        changeSeconds = fingerprint.changeSeconds
        changeNanoseconds = fingerprint.changeNanoseconds
        self.handle = handle
    }

    func withReaderDescriptor<T: Sendable>(
        _ body: @escaping @Sendable (Int32) async throws -> T
    ) async throws -> T {
        try transferVerificationCheckTaskCancellation()
        let descriptorOwner = try handle.openReaderDescriptor()
        defer { descriptorOwner.close() }
        let descriptor = try descriptorOwner.withDescriptor { $0 }
        try transferVerificationCheckTaskCancellation()
        return try await body(descriptor)
    }
}

fileprivate final class TransferVerificationManifestStorage: @unchecked Sendable {
    let authority: TransferVerificationRootAuthority
    let pathStorage: TransferVerificationPathStorage
    let regularFiles: [TransferVerificationRegularFileEntry]
    private let regularFileEntryIndexByNodeIndex: [Int]

    init(
        authority: TransferVerificationRootAuthority,
        pathStorage: TransferVerificationPathStorage,
        regularFiles: [TransferVerificationRegularFileEntry],
        regularFileNodeIndices: [Int],
        cancellation: TransferVerificationCancellationState
    ) throws {
        precondition(regularFiles.count == regularFileNodeIndices.count)
        try cancellation.check()
        self.authority = authority
        self.pathStorage = pathStorage
        self.regularFiles = regularFiles
        var entryIndices = [Int](repeating: -1, count: pathStorage.nodes.count)
        for (entryIndex, nodeIndex) in regularFileNodeIndices.enumerated() {
            if entryIndex.isMultiple(of: 256) {
                try cancellation.check()
            }
            precondition(entryIndices[nodeIndex] == -1)
            entryIndices[nodeIndex] = entryIndex
        }
        try cancellation.check()
        regularFileEntryIndexByNodeIndex = entryIndices
    }

    func regularFile(atNodeIndex nodeIndex: Int) -> TransferVerificationRegularFileEntry? {
        guard regularFileEntryIndexByNodeIndex.indices.contains(nodeIndex) else {
            return nil
        }
        let entryIndex = regularFileEntryIndexByNodeIndex[nodeIndex]
        guard entryIndex >= 0 else { return nil }
        return regularFiles[entryIndex]
    }

    func close() {
        authority.close()
    }

    deinit {
        close()
    }
}

struct TransferVerificationRegularFilePair: @unchecked Sendable {
    let source: TransferVerificationRegularFileEntry
    let staged: TransferVerificationRegularFileEntry
}

struct TransferVerificationManifest: @unchecked Sendable {
    let rootURL: URL
    let rootIdentity: FileIdentity
    let comparisonPolicy: FilenameComparisonPolicy
    let regularFileCount: Int
    let logicalByteCount: Int64
    fileprivate let storage: TransferVerificationManifestStorage

    fileprivate init(
        rootURL: URL,
        rootIdentity: FileIdentity,
        comparisonPolicy: FilenameComparisonPolicy,
        regularFileCount: Int,
        logicalByteCount: Int64,
        storage: TransferVerificationManifestStorage
    ) {
        self.rootURL = rootURL
        self.rootIdentity = rootIdentity
        self.comparisonPolicy = comparisonPolicy
        self.regularFileCount = regularFileCount
        self.logicalByteCount = logicalByteCount
        self.storage = storage
    }

    var regularFiles: [TransferVerificationRegularFileEntry] {
        storage.regularFiles
    }

    var pathStorageMetrics: TransferVerificationPathStorageMetrics {
        storage.pathStorage.metrics
    }

    /// Returns whether both manifests retain the same root authority token.
    ///
    /// This is intentionally internal rather than debug-only.  A builder's
    /// `recapture` implementation is required to return a fresh manifest with
    /// an independently closeable authority; callers use this comparison to
    /// fail closed before invoking `requireStable` or closing a returned
    /// manifest when a custom builder violates that contract.
    func hasSameAuthority(as other: TransferVerificationManifest) -> Bool {
        authorityToken == other.authorityToken
    }

    /// The token is an internal identity value only. It is never included in
    /// verification errors, summaries, or progress values.
    var authorityToken: TransferVerificationRootAuthorityToken {
        storage.authority.authorityToken
    }

    #if DEBUG
    var backingStorageObjectForTesting: AnyObject {
        storage
    }

    static func makeSyntheticPairForTesting(
        descendantCount: Int,
        regularFileDepth: Int
    ) throws -> (source: TransferVerificationManifest, staged: TransferVerificationManifest) {
        guard descendantCount > 0,
              descendantCount <= TransferVerificationLimits.production.maxDescendants,
              regularFileDepth > 0,
              regularFileDepth <= TransferVerificationLimits.production.maxDepth,
              descendantCount >= regularFileDepth
        else {
            throw TransferVerificationManifestError.scopeTooLarge
        }

        let sourceContext = try makeSyntheticAuthorityForTesting()
        let sourceAuthority = sourceContext.authority
        let rootFingerprint = sourceContext.rootFingerprint
        var sourceManifest: TransferVerificationManifest?
        var completed = false
        defer {
            if !completed {
                sourceManifest?.close()
                sourceAuthority.close()
            }
        }

        var arena = TransferVerificationPathArena(
            rootKind: .directory,
            rootFingerprint: rootFingerprint,
            symbolicLinkPayload: nil
        )
        var parentIndex = 0
        let directoryCount = regularFileDepth - 1
        if directoryCount > 0 {
            for directoryOffset in 0..<directoryCount {
                if directoryOffset.isMultiple(of: 256) {
                    try transferVerificationCheckTaskCancellation()
                }
                parentIndex = try arena.appendChild(
                    parentIndex: parentIndex,
                    rawName: [UInt8(ascii: "d")],
                    displayName: "d",
                    comparisonComponent: "d",
                    kind: .directory,
                    fingerprint: TransferVerificationNodeFingerprint(
                        device: 1,
                        inode: UInt64(directoryOffset + 2),
                        mode: UInt32(S_IFDIR) | 0o700,
                        size: 0
                    ),
                    symbolicLinkPayload: nil
                )
            }
        }

        let regularFileCount = descendantCount - directoryCount
        var regularFileNodeIndices: [Int] = []
        regularFileNodeIndices.reserveCapacity(regularFileCount)
        for fileOffset in 0..<regularFileCount {
            if fileOffset.isMultiple(of: 256) {
                try transferVerificationCheckTaskCancellation()
            }
            let name = "f\(fileOffset)"
            let nodeIndex = try arena.appendChild(
                parentIndex: parentIndex,
                rawName: Array(name.utf8),
                displayName: name,
                comparisonComponent: name,
                kind: .regularFile,
                fingerprint: TransferVerificationNodeFingerprint(
                    device: 1,
                    inode: UInt64(directoryCount + fileOffset + 2),
                    mode: UInt32(S_IFREG) | 0o600,
                    size: 0
                ),
                symbolicLinkPayload: nil
            )
            regularFileNodeIndices.append(nodeIndex)
        }
        try transferVerificationCheckTaskCancellation()

        let sourcePathStorage = arena.freeze()
        let source = try makeSyntheticManifestForTesting(
            authority: sourceAuthority,
            rootFingerprint: rootFingerprint,
            pathStorage: sourcePathStorage,
            regularFileNodeIndices: regularFileNodeIndices
        )
        sourceManifest = source

        let stagedContext = try makeSyntheticAuthorityForTesting()
        guard stagedContext.rootFingerprint == rootFingerprint else {
            stagedContext.authority.close()
            throw TransferVerificationManifestError.changed
        }
        let stagedPathStorage = TransferVerificationPathStorage(
            nodes: sourcePathStorage.nodes.map { $0 },
            metrics: sourcePathStorage.metrics
        )
        let staged = try makeSyntheticManifestForTesting(
            authority: stagedContext.authority,
            rootFingerprint: rootFingerprint,
            pathStorage: stagedPathStorage,
            regularFileNodeIndices: regularFileNodeIndices
        )
        completed = true
        return (source, staged)
    }

    func sharesAuthorityForTesting(
        with other: TransferVerificationManifest
    ) -> Bool {
        hasSameAuthority(as: other)
    }

    private static func makeSyntheticManifestForTesting(
        authority: TransferVerificationRootAuthority,
        rootFingerprint: TransferVerificationNodeFingerprint,
        pathStorage: TransferVerificationPathStorage,
        regularFileNodeIndices: [Int]
    ) throws -> TransferVerificationManifest {
        var completed = false
        defer {
            if !completed {
                authority.close()
            }
        }
        var regularFiles: [TransferVerificationRegularFileEntry] = []
        regularFiles.reserveCapacity(regularFileNodeIndices.count)
        for (entryIndex, nodeIndex) in regularFileNodeIndices.enumerated() {
            if entryIndex.isMultiple(of: 256) {
                try transferVerificationCheckTaskCancellation()
            }
            regularFiles.append(
                TransferVerificationRegularFileEntry(
                    fingerprint: pathStorage.nodes[nodeIndex].fingerprint,
                    handle: TransferVerificationRegularFileHandle(
                        authority: authority,
                        pathStorage: pathStorage,
                        nodeIndex: nodeIndex
                    )
                )
            )
        }
        try transferVerificationCheckTaskCancellation()
        let storage = try TransferVerificationManifestStorage(
            authority: authority,
            pathStorage: pathStorage,
            regularFiles: regularFiles,
            regularFileNodeIndices: regularFileNodeIndices,
            cancellation: TransferVerificationCancellationState()
        )
        let rootIdentity = FileIdentity(
            entryIdentifier: rootFingerprint.identityToken,
            resolvedIdentifier: rootFingerprint.identityToken
        )
        let manifest = TransferVerificationManifest(
            rootURL: URL(filePath: "/private", directoryHint: .isDirectory),
            rootIdentity: rootIdentity,
            comparisonPolicy: .caseSensitiveCanonical,
            regularFileCount: regularFileNodeIndices.count,
            logicalByteCount: 0,
            storage: storage
        )
        completed = true
        return manifest
    }

    private static func makeSyntheticAuthorityForTesting() throws -> (
        authority: TransferVerificationRootAuthority,
        rootFingerprint: TransferVerificationNodeFingerprint
    ) {
        let descriptorLifecycle = TransferVerificationDescriptorLifecycle(onEvent: nil)
        let parentDescriptorValue = try transferVerificationOpen(
            path: Array("/".utf8),
            flags: transferVerificationDirectoryOpenFlags,
            failureContext: .parentOpen
        )
        let parentDescriptor = descriptorLifecycle.own(
            parentDescriptorValue,
            role: .rootParent
        )
        let rootDescriptorValue: Int32
        do {
            rootDescriptorValue = try transferVerificationOpen(
                path: Array("/private".utf8),
                flags: transferVerificationDirectoryOpenFlags,
                failureContext: .parentOpen
            )
        } catch {
            parentDescriptor.close()
            throw error
        }
        let rootDescriptor = descriptorLifecycle.own(
            rootDescriptorValue,
            role: .rootDirectory
        )
        let rootFingerprint: TransferVerificationNodeFingerprint
        do {
            rootFingerprint = TransferVerificationNodeFingerprint(
                try transferVerificationFstat(rootDescriptorValue)
            )
        } catch {
            rootDescriptor.close()
            parentDescriptor.close()
            throw error
        }
        return (
            TransferVerificationRootAuthority(
                parentDescriptor: parentDescriptor,
                directoryRootDescriptor: rootDescriptor,
                rawRootName: Array("private".utf8),
                rootFingerprint: rootFingerprint,
                rootKind: .directory,
                descriptorLifecycle: descriptorLifecycle,
                afterReaderDirectoryOpen: nil
            ),
            rootFingerprint
        )
    }
    #endif

    func regularFilePairs(
        matching staged: TransferVerificationManifest
    ) throws -> [TransferVerificationRegularFilePair] {
        #if DEBUG
        try regularFilePairs(matching: staged, testHooks: .none)
        #else
        try regularFilePairsCore(matching: staged)
        #endif
    }

    #if DEBUG
    func regularFilePairs(
        matching staged: TransferVerificationManifest,
        testHooks: TransferVerificationManifestTestHooks
    ) throws -> [TransferVerificationRegularFilePair] {
        try regularFilePairsCore(
            matching: staged,
            duringNodeComparison: testHooks.duringContentShapeNodeComparison,
            duringPairMaterialization: testHooks.duringRegularFilePairMaterialization
        )
    }
    #endif

    #if DEBUG
    private func regularFilePairsCore(
        matching staged: TransferVerificationManifest,
        duringNodeComparison: (@Sendable (Int) -> Void)?,
        duringPairMaterialization: (@Sendable (Int) -> Void)?
    ) throws -> [TransferVerificationRegularFilePair] {
        try transferVerificationCheckTaskCancellation()
        guard comparisonPolicy == staged.comparisonPolicy else {
            throw TransferVerificationManifestError.structureMismatch
        }
        var result: [TransferVerificationRegularFilePair] = []
        result.reserveCapacity(regularFileCount)
        try transferVerificationCompareContentShape(
            source: storage,
            staged: staged.storage,
            duringNodeComparison: duringNodeComparison
        ) { sourceNodeIndex, stagedNodeIndex in
            duringPairMaterialization?(result.count)
            try transferVerificationCheckTaskCancellation()
            guard let sourceEntry = storage.regularFile(atNodeIndex: sourceNodeIndex),
                  let stagedEntry = staged.storage.regularFile(
                    atNodeIndex: stagedNodeIndex
                  )
            else {
                throw TransferVerificationManifestError.structureMismatch
            }
            result.append(
                TransferVerificationRegularFilePair(
                    source: sourceEntry,
                    staged: stagedEntry
                )
            )
        }
        try transferVerificationCheckTaskCancellation()
        return result
    }
    #else
    private func regularFilePairsCore(
        matching staged: TransferVerificationManifest
    ) throws -> [TransferVerificationRegularFilePair] {
        try transferVerificationCheckTaskCancellation()
        guard comparisonPolicy == staged.comparisonPolicy else {
            throw TransferVerificationManifestError.structureMismatch
        }
        var result: [TransferVerificationRegularFilePair] = []
        result.reserveCapacity(regularFileCount)
        try transferVerificationCompareContentShape(
            source: storage,
            staged: staged.storage
        ) { sourceNodeIndex, stagedNodeIndex in
            try transferVerificationCheckTaskCancellation()
            guard let sourceEntry = storage.regularFile(atNodeIndex: sourceNodeIndex),
                  let stagedEntry = staged.storage.regularFile(
                    atNodeIndex: stagedNodeIndex
                  )
            else {
                throw TransferVerificationManifestError.structureMismatch
            }
            result.append(
                TransferVerificationRegularFilePair(
                    source: sourceEntry,
                    staged: stagedEntry
                )
            )
        }
        try transferVerificationCheckTaskCancellation()
        return result
    }
    #endif

    func close() {
        storage.close()
    }
}

protocol TransferVerificationManifestBuilding: Sendable {
    func capture(
        at rootURL: URL,
        identifiedBy expectedIdentity: FileIdentity,
        comparisonPolicy: FilenameComparisonPolicy
    ) async throws -> TransferVerificationManifest

    /// Recaptures `manifest` into a new generation.
    ///
    /// The returned manifest must own a fresh root authority that is
    /// independently closeable from the input manifest and therefore carry a
    /// different authority identity token. Implementations must not return the
    /// input manifest itself or share its root authority.
    func recapture(
        _ manifest: TransferVerificationManifest
    ) async throws -> TransferVerificationManifest

    func requireStable(
        _ current: TransferVerificationManifest,
        against captured: TransferVerificationManifest
    ) throws

    func requireEquivalentContentShape(
        source: TransferVerificationManifest,
        staged: TransferVerificationManifest
    ) throws
}

#if DEBUG
struct TransferVerificationManifestTestHooks: @unchecked Sendable {
    let afterRootDirectoryOpen: (@Sendable () throws -> Void)?
    let afterRegularFileInspection: (@Sendable ([String]) throws -> Void)?
    let afterSymbolicLinkInspection: (@Sendable ([String]) throws -> Void)?
    let beforeDirectoryRead: (@Sendable () throws -> Void)?
    let onDuplicatedDescriptor: (@Sendable (Int32) -> Void)?
    let onDescriptorEvent: (@Sendable (TransferVerificationDescriptorEvent) -> Void)?
    let afterReaderDirectoryOpen: (@Sendable ([String]) throws -> Void)?
    let duplicateDescriptor: (@Sendable (Int32) -> Int32)?
    let duringRegularFileMaterialization: (@Sendable (Int) -> Void)?
    let duringStableNodeComparison: (@Sendable (Int) -> Void)?
    let duringStableChildComparison: (@Sendable (Int) -> Void)?
    let duringContentShapeNodeComparison: (@Sendable (Int) -> Void)?
    let duringRegularFilePairMaterialization: (@Sendable (Int) -> Void)?

    init(
        afterRootDirectoryOpen: (@Sendable () throws -> Void)? = nil,
        afterRegularFileInspection: (@Sendable ([String]) throws -> Void)? = nil,
        afterSymbolicLinkInspection: (@Sendable ([String]) throws -> Void)? = nil,
        beforeDirectoryRead: (@Sendable () throws -> Void)? = nil,
        onDuplicatedDescriptor: (@Sendable (Int32) -> Void)? = nil,
        onDescriptorEvent: (@Sendable (TransferVerificationDescriptorEvent) -> Void)? = nil,
        afterReaderDirectoryOpen: (@Sendable ([String]) throws -> Void)? = nil,
        duplicateDescriptor: (@Sendable (Int32) -> Int32)? = nil,
        duringRegularFileMaterialization: (@Sendable (Int) -> Void)? = nil,
        duringStableNodeComparison: (@Sendable (Int) -> Void)? = nil,
        duringStableChildComparison: (@Sendable (Int) -> Void)? = nil,
        duringContentShapeNodeComparison: (@Sendable (Int) -> Void)? = nil,
        duringRegularFilePairMaterialization: (@Sendable (Int) -> Void)? = nil
    ) {
        self.afterRootDirectoryOpen = afterRootDirectoryOpen
        self.afterRegularFileInspection = afterRegularFileInspection
        self.afterSymbolicLinkInspection = afterSymbolicLinkInspection
        self.beforeDirectoryRead = beforeDirectoryRead
        self.onDuplicatedDescriptor = onDuplicatedDescriptor
        self.onDescriptorEvent = onDescriptorEvent
        self.afterReaderDirectoryOpen = afterReaderDirectoryOpen
        self.duplicateDescriptor = duplicateDescriptor
        self.duringRegularFileMaterialization = duringRegularFileMaterialization
        self.duringStableNodeComparison = duringStableNodeComparison
        self.duringStableChildComparison = duringStableChildComparison
        self.duringContentShapeNodeComparison = duringContentShapeNodeComparison
        self.duringRegularFilePairMaterialization = duringRegularFilePairMaterialization
    }

    static let none = Self()
}
#endif

private struct TransferVerificationCaptureHooks: @unchecked Sendable {
    #if DEBUG
    let afterRootDirectoryOpen: (@Sendable () throws -> Void)?
    let afterRegularFileInspection: (@Sendable ([String]) throws -> Void)?
    let afterSymbolicLinkInspection: (@Sendable ([String]) throws -> Void)?
    let beforeDirectoryRead: (@Sendable () throws -> Void)?
    let onDuplicatedDescriptor: (@Sendable (Int32) -> Void)?
    let onDescriptorEvent: (@Sendable (TransferVerificationDescriptorEvent) -> Void)?
    let afterReaderDirectoryOpen: (@Sendable ([String]) throws -> Void)?
    let duplicateDescriptor: (@Sendable (Int32) -> Int32)?
    let duringRegularFileMaterialization: (@Sendable (Int) -> Void)?
    let duringContentShapeNodeComparison: (@Sendable (Int) -> Void)?
    let duringRegularFilePairMaterialization: (@Sendable (Int) -> Void)?

    init(_ testHooks: TransferVerificationManifestTestHooks) {
        afterRootDirectoryOpen = testHooks.afterRootDirectoryOpen
        afterRegularFileInspection = testHooks.afterRegularFileInspection
        afterSymbolicLinkInspection = testHooks.afterSymbolicLinkInspection
        beforeDirectoryRead = testHooks.beforeDirectoryRead
        onDuplicatedDescriptor = testHooks.onDuplicatedDescriptor
        onDescriptorEvent = testHooks.onDescriptorEvent
        afterReaderDirectoryOpen = testHooks.afterReaderDirectoryOpen
        duplicateDescriptor = testHooks.duplicateDescriptor
        duringRegularFileMaterialization = testHooks.duringRegularFileMaterialization
        duringContentShapeNodeComparison = testHooks.duringContentShapeNodeComparison
        duringRegularFilePairMaterialization = testHooks.duringRegularFilePairMaterialization
    }

    static let none = Self(.none)
    #else
    static let none = Self()
    #endif
}

struct LiveTransferVerificationManifestBuilder: TransferVerificationManifestBuilding {
    private let limits: TransferVerificationLimits
    #if DEBUG
    private let testHooks: TransferVerificationManifestTestHooks
    #endif

    init(limits: TransferVerificationLimits = .production) {
        self.limits = limits
        #if DEBUG
        testHooks = .none
        #endif
    }

    #if DEBUG
    init(
        limits: TransferVerificationLimits = .production,
        testHooks: TransferVerificationManifestTestHooks
    ) {
        self.limits = limits
        self.testHooks = testHooks
    }
    #endif

    func capture(
        at rootURL: URL,
        identifiedBy expectedIdentity: FileIdentity,
        comparisonPolicy: FilenameComparisonPolicy
    ) async throws -> TransferVerificationManifest {
        let cancellation = TransferVerificationCancellationState()
        #if DEBUG
        let captureHooks = TransferVerificationCaptureHooks(testHooks)
        #else
        let captureHooks = TransferVerificationCaptureHooks.none
        #endif
        return try await withTaskCancellationHandler {
            do {
                return try await Task.detached(priority: .utility) {
                    try Self.captureSynchronously(
                        at: rootURL,
                        identifiedBy: expectedIdentity,
                        comparisonPolicy: comparisonPolicy,
                        limits: limits,
                        hooks: captureHooks,
                        cancellation: cancellation
                    )
                }.value
            } catch let error as TransferVerificationManifestError {
                throw error
            } catch is CancellationError {
                throw TransferVerificationManifestError.cancelled
            } catch {
                throw TransferVerificationManifestError.readFailed
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func recapture(
        _ manifest: TransferVerificationManifest
    ) async throws -> TransferVerificationManifest {
        try await capture(
            at: manifest.rootURL,
            identifiedBy: manifest.rootIdentity,
            comparisonPolicy: manifest.comparisonPolicy
        )
    }

    func requireStable(
        _ current: TransferVerificationManifest,
        against captured: TransferVerificationManifest
    ) throws {
        try transferVerificationCheckTaskCancellation()
        guard current.rootURL == captured.rootURL,
              current.rootIdentity.entryIdentifier
                == captured.rootIdentity.entryIdentifier,
              current.comparisonPolicy == captured.comparisonPolicy
        else {
            throw TransferVerificationManifestError.changed
        }
        let currentNodes = current.storage.pathStorage.nodes
        let capturedNodes = captured.storage.pathStorage.nodes
        guard currentNodes.count == capturedNodes.count else {
            throw TransferVerificationManifestError.changed
        }
        for nodeIndex in currentNodes.indices {
            #if DEBUG
            testHooks.duringStableNodeComparison?(nodeIndex)
            #endif
            try transferVerificationCheckTaskCancellation()
            let currentNode = currentNodes[nodeIndex]
            let capturedNode = capturedNodes[nodeIndex]
            guard currentNode.parentIndex == capturedNode.parentIndex,
                  currentNode.depth == capturedNode.depth,
                  currentNode.rawName == capturedNode.rawName,
                  currentNode.displayName == capturedNode.displayName,
                  currentNode.comparisonComponent == capturedNode.comparisonComponent,
                  currentNode.kind == capturedNode.kind,
                  currentNode.fingerprint == capturedNode.fingerprint,
                  currentNode.symbolicLinkPayload == capturedNode.symbolicLinkPayload,
                  currentNode.childIndices.count == capturedNode.childIndices.count
            else {
                throw TransferVerificationManifestError.changed
            }
            for childOffset in currentNode.childIndices.indices {
                #if DEBUG
                testHooks.duringStableChildComparison?(childOffset)
                #endif
                if childOffset.isMultiple(of: 256) {
                    try transferVerificationCheckTaskCancellation()
                }
                guard currentNode.childIndices[childOffset]
                    == capturedNode.childIndices[childOffset]
                else {
                    throw TransferVerificationManifestError.changed
                }
            }
            try transferVerificationCheckTaskCancellation()
        }
        try transferVerificationCheckTaskCancellation()
    }

    func requireEquivalentContentShape(
        source: TransferVerificationManifest,
        staged: TransferVerificationManifest
    ) throws {
        try transferVerificationCheckTaskCancellation()
        guard source.comparisonPolicy == staged.comparisonPolicy else {
            throw TransferVerificationManifestError.structureMismatch
        }
        #if DEBUG
        try transferVerificationCompareContentShape(
            source: source.storage,
            staged: staged.storage,
            duringNodeComparison: testHooks.duringContentShapeNodeComparison
        )
        #else
        try transferVerificationCompareContentShape(
            source: source.storage,
            staged: staged.storage
        )
        #endif
    }

    private static func captureSynchronously(
        at rootURL: URL,
        identifiedBy expectedIdentity: FileIdentity,
        comparisonPolicy: FilenameComparisonPolicy,
        limits: TransferVerificationLimits,
        hooks: TransferVerificationCaptureHooks,
        cancellation: TransferVerificationCancellationState
    ) throws -> TransferVerificationManifest {
        try cancellation.check()
        #if DEBUG
        let descriptorLifecycle = TransferVerificationDescriptorLifecycle(
            onEvent: hooks.onDescriptorEvent
        )
        #else
        let descriptorLifecycle = TransferVerificationDescriptorLifecycle()
        #endif
        let location = try TransferVerificationRootLocation(rootURL)
        let parentDescriptorValue = try transferVerificationOpen(
            path: location.parentPath,
            flags: transferVerificationDirectoryOpenFlags,
            failureContext: .parentOpen
        )
        #if DEBUG
        let parentDescriptor = descriptorLifecycle.own(
            parentDescriptorValue,
            role: .rootParent,
            duplicateDescriptor: hooks.duplicateDescriptor
                ?? transferVerificationDuplicateDescriptor
        )
        #else
        let parentDescriptor = descriptorLifecycle.own(parentDescriptorValue)
        #endif
        var rootDirectoryDescriptor: TransferVerificationOwnedDescriptor?
        var authority: TransferVerificationRootAuthority?
        var completed = false
        defer {
            if !completed {
                authority?.close()
                rootDirectoryDescriptor?.close()
                parentDescriptor.close()
            }
        }

        let initialRoot = try transferVerificationStatAt(
            parentDescriptorValue,
            name: location.rootName,
            flags: AT_SYMLINK_NOFOLLOW,
            changeMeansChanged: true
        )
        let rootFingerprint = TransferVerificationNodeFingerprint(initialRoot)
        guard rootFingerprint.identityToken == expectedIdentity.entryIdentifier else {
            throw TransferVerificationManifestError.changed
        }
        let rootKind = try transferVerificationKind(of: initialRoot)
        var budget = TransferVerificationBudget(limits: limits)
        try budget.includeRoot(
            regularFileSize: rootKind == .regularFile ? rootFingerprint.size : nil
        )

        if rootKind == .directory {
            let openedRoot = try transferVerificationOpenAt(
                parentDescriptorValue,
                name: location.rootName,
                flags: transferVerificationDirectoryOpenFlags,
                failureContext: .postInspectionOpen
            )
            #if DEBUG
            rootDirectoryDescriptor = descriptorLifecycle.own(
                openedRoot,
                role: .rootDirectory,
                duplicateDescriptor: hooks.duplicateDescriptor
                    ?? transferVerificationDuplicateDescriptor
            )
            #else
            rootDirectoryDescriptor = descriptorLifecycle.own(openedRoot)
            #endif
            let openedInformation = try transferVerificationFstat(openedRoot)
            guard TransferVerificationNodeFingerprint(openedInformation) == rootFingerprint else {
                throw TransferVerificationManifestError.changed
            }
            #if DEBUG
            try hooks.afterRootDirectoryOpen?()
            #endif
            try cancellation.check()
            let namespace = try transferVerificationStatAt(
                parentDescriptorValue,
                name: location.rootName,
                flags: AT_SYMLINK_NOFOLLOW,
                changeMeansChanged: true
            )
            let openedAgain = try transferVerificationFstat(openedRoot)
            guard TransferVerificationNodeFingerprint(namespace) == rootFingerprint,
                  TransferVerificationNodeFingerprint(openedAgain) == rootFingerprint
            else {
                throw TransferVerificationManifestError.changed
            }
        }

        #if DEBUG
        let rootAuthority = TransferVerificationRootAuthority(
            parentDescriptor: parentDescriptor,
            directoryRootDescriptor: rootDirectoryDescriptor,
            rawRootName: location.rootName,
            rootFingerprint: rootFingerprint,
            rootKind: rootKind,
            descriptorLifecycle: descriptorLifecycle,
            afterReaderDirectoryOpen: hooks.afterReaderDirectoryOpen
        )
        #else
        let rootAuthority = TransferVerificationRootAuthority(
            parentDescriptor: parentDescriptor,
            directoryRootDescriptor: rootDirectoryDescriptor,
            rawRootName: location.rootName,
            rootFingerprint: rootFingerprint,
            rootKind: rootKind,
            descriptorLifecycle: descriptorLifecycle
        )
        #endif
        authority = rootAuthority

        var rootSymbolicLinkPayload: [UInt8]?
        var regularNodeIndices: [Int] = []

        switch rootKind {
        case .regularFile:
            #if DEBUG
            try hooks.afterRegularFileInspection?([])
            #endif
            try cancellation.check()
            try validateRegularFile(
                in: parentDescriptorValue,
                name: location.rootName,
                expected: rootFingerprint,
                descriptorLifecycle: descriptorLifecycle
            )
            regularNodeIndices.append(0)

        case .symbolicLink:
            #if DEBUG
            try hooks.afterSymbolicLinkInspection?([])
            #endif
            try cancellation.check()
            let payload = try transferVerificationReadLink(
                in: parentDescriptorValue,
                name: location.rootName
            )
            let finalRoot = try transferVerificationStatAt(
                parentDescriptorValue,
                name: location.rootName,
                flags: AT_SYMLINK_NOFOLLOW,
                changeMeansChanged: true
            )
            guard TransferVerificationNodeFingerprint(finalRoot) == rootFingerprint else {
                throw TransferVerificationManifestError.changed
            }
            rootSymbolicLinkPayload = payload

        case .directory:
            break
        }

        var arena = TransferVerificationPathArena(
            rootKind: rootKind,
            rootFingerprint: rootFingerprint,
            symbolicLinkPayload: rootSymbolicLinkPayload
        )
        if rootKind == .directory {
            try traverseDirectories(
                authority: rootAuthority,
                comparisonPolicy: comparisonPolicy,
                budget: &budget,
                arena: &arena,
                regularNodeIndices: &regularNodeIndices,
                descriptorLifecycle: descriptorLifecycle,
                hooks: hooks,
                cancellation: cancellation
            )
            let finalNamespace = try transferVerificationStatAt(
                parentDescriptorValue,
                name: location.rootName,
                flags: AT_SYMLINK_NOFOLLOW,
                changeMeansChanged: true
            )
            let rootDescriptor = try rootDirectoryDescriptor!.withDescriptor { $0 }
            let finalOpenedRoot = try transferVerificationFstat(rootDescriptor)
            guard TransferVerificationNodeFingerprint(finalNamespace) == rootFingerprint,
                  TransferVerificationNodeFingerprint(finalOpenedRoot) == rootFingerprint
            else {
                throw TransferVerificationManifestError.changed
            }
        }

        try cancellation.check()
        let pathStorage = arena.freeze()
        var regularFiles: [TransferVerificationRegularFileEntry] = []
        regularFiles.reserveCapacity(regularNodeIndices.count)
        for (entryIndex, nodeIndex) in regularNodeIndices.enumerated() {
            #if DEBUG
            hooks.duringRegularFileMaterialization?(entryIndex)
            #endif
            try cancellation.check()
            let node = pathStorage.nodes[nodeIndex]
            let handle = TransferVerificationRegularFileHandle(
                authority: rootAuthority,
                pathStorage: pathStorage,
                nodeIndex: nodeIndex
            )
            regularFiles.append(
                TransferVerificationRegularFileEntry(
                    fingerprint: node.fingerprint,
                    handle: handle
                )
            )
        }
        try cancellation.check()
        let storage = try TransferVerificationManifestStorage(
            authority: rootAuthority,
            pathStorage: pathStorage,
            regularFiles: regularFiles,
            regularFileNodeIndices: regularNodeIndices,
            cancellation: cancellation
        )
        let manifest = TransferVerificationManifest(
            rootURL: rootURL,
            rootIdentity: expectedIdentity,
            comparisonPolicy: comparisonPolicy,
            regularFileCount: budget.regularFileCount,
            logicalByteCount: budget.logicalByteCount,
            storage: storage
        )
        try cancellation.check()
        completed = true
        return manifest
    }

    private static func traverseDirectories(
        authority: TransferVerificationRootAuthority,
        comparisonPolicy: FilenameComparisonPolicy,
        budget: inout TransferVerificationBudget,
        arena: inout TransferVerificationPathArena,
        regularNodeIndices: inout [Int],
        descriptorLifecycle: TransferVerificationDescriptorLifecycle,
        hooks: TransferVerificationCaptureHooks,
        cancellation: TransferVerificationCancellationState
    ) throws {
        var pendingDirectoryIndices = [0]
        while let directoryIndex = pendingDirectoryIndices.popLast() {
            try cancellation.check()
            let expectedDirectory = arena.nodes[directoryIndex].fingerprint
            let parentDepth = arena.nodes[directoryIndex].depth
            let directoryOwner = try authority.openTraversalDirectory(
                nodes: arena.nodes,
                nodeIndex: directoryIndex,
                cancellation: cancellation
            )
            var childDirectoryIndices: [Int] = []
            do {
                let descriptor = try directoryOwner.withDescriptor { $0 }
                #if DEBUG
                try hooks.beforeDirectoryRead?()
                #endif
                try cancellation.check()
                let maximumNames = budget.maximumChildren(
                    atParentDepth: parentDepth
                )
                #if DEBUG
                let names = try transferVerificationDirectoryNames(
                    descriptor,
                    maximumNames: maximumNames,
                    cancellation: cancellation,
                    descriptorLifecycle: descriptorLifecycle,
                    onDuplicate: hooks.onDuplicatedDescriptor
                )
                #else
                let names = try transferVerificationDirectoryNames(
                    descriptor,
                    maximumNames: maximumNames,
                    cancellation: cancellation,
                    descriptorLifecycle: descriptorLifecycle
                )
                #endif
                try budget.reserveDescendants(
                    names.count,
                    atDepth: parentDepth + 1
                )
                for rawName in names {
                    try cancellation.check()
                    let displayName = try TransferVerificationFilenameDecoder.decode(rawName)
                    let comparisonComponent = comparisonPolicy.key(for: displayName)
                    try arena.requireAvailable(
                        comparisonComponent: comparisonComponent,
                        under: directoryIndex
                    )
                    let inspected = try transferVerificationStatAt(
                        descriptor,
                        name: rawName,
                        flags: AT_SYMLINK_NOFOLLOW,
                        changeMeansChanged: true
                    )
                    let fingerprint = TransferVerificationNodeFingerprint(inspected)
                    let kind = try transferVerificationKind(of: inspected)
                    if kind == .regularFile {
                        try budget.includeRegularFile(fingerprint.size)
                    }
                    var symbolicLinkPayload: [UInt8]?

                    switch kind {
                    case .regularFile:
                        #if DEBUG
                        if let hook = hooks.afterRegularFileInspection {
                            try hook(
                                arena.displayComponents(to: directoryIndex)
                                + [displayName]
                            )
                        }
                        #endif
                        try cancellation.check()
                        try validateRegularFile(
                            in: descriptor,
                            name: rawName,
                            expected: fingerprint,
                            descriptorLifecycle: descriptorLifecycle
                        )

                    case .symbolicLink:
                        #if DEBUG
                        if let hook = hooks.afterSymbolicLinkInspection {
                            try hook(
                                arena.displayComponents(to: directoryIndex)
                                + [displayName]
                            )
                        }
                        #endif
                        try cancellation.check()
                        symbolicLinkPayload = try transferVerificationReadLink(
                            in: descriptor,
                            name: rawName
                        )
                        let finalInformation = try transferVerificationStatAt(
                            descriptor,
                            name: rawName,
                            flags: AT_SYMLINK_NOFOLLOW,
                            changeMeansChanged: true
                        )
                        guard TransferVerificationNodeFingerprint(finalInformation)
                            == fingerprint
                        else {
                            throw TransferVerificationManifestError.changed
                        }

                    case .directory:
                        let childValue = try transferVerificationOpenAt(
                            descriptor,
                            name: rawName,
                            flags: transferVerificationDirectoryOpenFlags,
                            failureContext: .postInspectionOpen
                        )
                        #if DEBUG
                        let childOwner = descriptorLifecycle.own(
                            childValue,
                            role: .traversalDirectory
                        )
                        #else
                        let childOwner = descriptorLifecycle.own(childValue)
                        #endif
                        do {
                            let opened = try transferVerificationFstat(childValue)
                            guard TransferVerificationNodeFingerprint(opened) == fingerprint else {
                                throw TransferVerificationManifestError.changed
                            }
                            let finalNamespace = try transferVerificationStatAt(
                                descriptor,
                                name: rawName,
                                flags: AT_SYMLINK_NOFOLLOW,
                                changeMeansChanged: true
                            )
                            guard TransferVerificationNodeFingerprint(finalNamespace)
                                == fingerprint
                            else {
                                throw TransferVerificationManifestError.changed
                            }
                        } catch {
                            childOwner.close()
                            throw error
                        }
                        childOwner.close()
                    }

                    let childIndex = try arena.appendChild(
                        parentIndex: directoryIndex,
                        rawName: rawName,
                        displayName: displayName,
                        comparisonComponent: comparisonComponent,
                        kind: kind,
                        fingerprint: fingerprint,
                        symbolicLinkPayload: symbolicLinkPayload
                    )
                    if kind == .regularFile {
                        regularNodeIndices.append(childIndex)
                    } else if kind == .directory {
                        childDirectoryIndices.append(childIndex)
                    }
                    try cancellation.check()
                }
                let finalDirectory = try transferVerificationFstat(descriptor)
                guard TransferVerificationNodeFingerprint(finalDirectory)
                    == expectedDirectory
                else {
                    throw TransferVerificationManifestError.changed
                }
            } catch {
                directoryOwner.close()
                throw error
            }
            directoryOwner.close()
            let finalNamespaceOwner = try authority.openTraversalDirectory(
                nodes: arena.nodes,
                nodeIndex: directoryIndex,
                cancellation: cancellation
            )
            finalNamespaceOwner.close()
            pendingDirectoryIndices.append(contentsOf: childDirectoryIndices.reversed())
        }
    }

    private static func validateRegularFile(
        in parentDescriptor: Int32,
        name: [UInt8],
        expected: TransferVerificationNodeFingerprint,
        descriptorLifecycle: TransferVerificationDescriptorLifecycle
    ) throws {
        let fileDescriptorValue = try transferVerificationOpenAt(
            parentDescriptor,
            name: name,
            flags: transferVerificationRegularOpenFlags,
            failureContext: .postInspectionOpen
        )
        #if DEBUG
        let fileDescriptor = descriptorLifecycle.own(
            fileDescriptorValue,
            role: .validationFile
        )
        #else
        let fileDescriptor = descriptorLifecycle.own(fileDescriptorValue)
        #endif
        defer { fileDescriptor.close() }
        let opened = try transferVerificationFstat(fileDescriptorValue)
        guard TransferVerificationNodeFingerprint(opened) == expected,
              try transferVerificationKind(of: opened) == .regularFile
        else {
            throw TransferVerificationManifestError.changed
        }
        let finalNamespace = try transferVerificationStatAt(
            parentDescriptor,
            name: name,
            flags: AT_SYMLINK_NOFOLLOW,
            changeMeansChanged: true
        )
        guard TransferVerificationNodeFingerprint(finalNamespace) == expected else {
            throw TransferVerificationManifestError.changed
        }
    }
}

private func transferVerificationCompareContentShapeCore(
    source: TransferVerificationManifestStorage,
    staged: TransferVerificationManifestStorage,
    duringNodeComparison: (@Sendable (Int) -> Void)?,
    onRegularFile: ((Int, Int) throws -> Void)? = nil
) throws {
    try transferVerificationCheckTaskCancellation()
    let sourceNodes = source.pathStorage.nodes
    let stagedNodes = staged.pathStorage.nodes
    guard !sourceNodes.isEmpty, !stagedNodes.isEmpty else {
        throw TransferVerificationManifestError.structureMismatch
    }
    var pending: [(source: Int, staged: Int)] = [(0, 0)]
    var comparedCount = 0
    while let pair = pending.popLast() {
        #if DEBUG
        duringNodeComparison?(comparedCount)
        #endif
        try transferVerificationCheckTaskCancellation()
        let sourceNode = sourceNodes[pair.source]
        let stagedNode = stagedNodes[pair.staged]
        guard sourceNode.kind == stagedNode.kind,
              sourceNode.childIndices.count == stagedNode.childIndices.count
        else {
            throw TransferVerificationManifestError.structureMismatch
        }
        switch sourceNode.kind {
        case .regularFile:
            guard sourceNode.fingerprint.size == stagedNode.fingerprint.size else {
                throw TransferVerificationManifestError.structureMismatch
            }
            try onRegularFile?(pair.source, pair.staged)
        case .symbolicLink:
            guard sourceNode.symbolicLinkPayload == stagedNode.symbolicLinkPayload else {
                throw TransferVerificationManifestError.structureMismatch
            }
        case .directory:
            break
        }
        var stagedChildrenByComparisonComponent: [String: Int] = [:]
        stagedChildrenByComparisonComponent.reserveCapacity(
            stagedNode.childIndices.count
        )
        for (childOffset, stagedChild) in stagedNode.childIndices.enumerated() {
            if childOffset.isMultiple(of: 256) {
                try transferVerificationCheckTaskCancellation()
            }
            let component = stagedNodes[stagedChild].comparisonComponent
            guard stagedChildrenByComparisonComponent.updateValue(
                stagedChild,
                forKey: component
            ) == nil else {
                throw TransferVerificationManifestError.structureMismatch
            }
        }
        try transferVerificationCheckTaskCancellation()
        for (childOffset, sourceChild) in sourceNode.childIndices.enumerated() {
            if childOffset.isMultiple(of: 256) {
                try transferVerificationCheckTaskCancellation()
            }
            let component = sourceNodes[sourceChild].comparisonComponent
            guard let stagedChild = stagedChildrenByComparisonComponent.removeValue(
                forKey: component
            ) else {
                throw TransferVerificationManifestError.structureMismatch
            }
            pending.append((sourceChild, stagedChild))
        }
        try transferVerificationCheckTaskCancellation()
        guard stagedChildrenByComparisonComponent.isEmpty else {
            throw TransferVerificationManifestError.structureMismatch
        }
        comparedCount += 1
    }
    guard comparedCount == sourceNodes.count,
          comparedCount == stagedNodes.count
    else {
        throw TransferVerificationManifestError.structureMismatch
    }
    try transferVerificationCheckTaskCancellation()
}

#if DEBUG
private func transferVerificationCompareContentShape(
    source: TransferVerificationManifestStorage,
    staged: TransferVerificationManifestStorage,
    duringNodeComparison: (@Sendable (Int) -> Void)? = nil,
    onRegularFile: ((Int, Int) throws -> Void)? = nil
) throws {
    try transferVerificationCompareContentShapeCore(
        source: source,
        staged: staged,
        duringNodeComparison: duringNodeComparison,
        onRegularFile: onRegularFile
    )
}
#endif

private func transferVerificationCompareContentShape(
    source: TransferVerificationManifestStorage,
    staged: TransferVerificationManifestStorage,
    onRegularFile: ((Int, Int) throws -> Void)? = nil
) throws {
    try transferVerificationCompareContentShapeCore(
        source: source,
        staged: staged,
        duringNodeComparison: nil,
        onRegularFile: onRegularFile
    )
}

private final class TransferVerificationCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.withLock { cancelled = true }
    }

    func check() throws {
        guard !lock.withLock({ cancelled }) else {
            throw TransferVerificationManifestError.cancelled
        }
    }
}

private struct TransferVerificationRootLocation: Sendable {
    let parentPath: [UInt8]
    let rootName: [UInt8]

    init(_ rootURL: URL) throws {
        guard rootURL.isFileURL else {
            throw TransferVerificationManifestError.unsupportedName
        }
        let bytes: [UInt8]? = rootURL.withUnsafeFileSystemRepresentation { representation in
            guard let representation else { return nil }
            let count = strlen(representation)
            return Array(
                UnsafeRawBufferPointer(start: representation, count: count)
                    .bindMemory(to: UInt8.self)
            )
        }
        guard let bytes else {
            throw TransferVerificationManifestError.unsupportedName
        }
        let parsed = try TransferVerificationRootPathParser.split(bytes)
        parentPath = parsed.parentPath
        rootName = parsed.rootName
    }
}

enum TransferVerificationRootPathParser {
    struct Components: Sendable, Equatable {
        let parentPath: [UInt8]
        let rootName: [UInt8]
    }

    static func split(_ bytes: [UInt8]) throws -> Components {
        guard !bytes.isEmpty,
              !bytes.contains(0),
              bytes.first == UInt8(ascii: "/"),
              let separator = bytes.lastIndex(of: UInt8(ascii: "/"))
        else {
            throw TransferVerificationManifestError.unsupportedName
        }
        let name = Array(bytes[bytes.index(after: separator)...])
        guard name != [UInt8(ascii: ".")],
              name != [UInt8(ascii: "."), UInt8(ascii: ".")]
        else {
            throw TransferVerificationManifestError.unsupportedName
        }
        _ = try TransferVerificationFilenameDecoder.decode(name)
        let parentBytes = Array(bytes[..<separator])
        return Components(
            parentPath: parentBytes.isEmpty ? [UInt8(ascii: "/")] : parentBytes,
            rootName: name
        )
    }
}

enum TransferVerificationPOSIXErrorClassifier {
    static func namespaceFailure(_ rawValue: Int32) -> TransferVerificationManifestError {
        switch rawValue {
        case ENOENT, ENOTDIR, ELOOP, ESTALE:
            .changed
        default:
            .readFailed
        }
    }

    static func parentOpenFailure(_ rawValue: Int32) -> TransferVerificationManifestError {
        namespaceFailure(rawValue)
    }

    static func postInspectionOpenFailure(
        _ rawValue: Int32
    ) -> TransferVerificationManifestError {
        switch rawValue {
        case EOPNOTSUPP, ENXIO:
            .changed
        default:
            namespaceFailure(rawValue)
        }
    }

    static func readLinkFailure(_ rawValue: Int32) -> TransferVerificationManifestError {
        if rawValue == EINVAL {
            return .changed
        }
        return namespaceFailure(rawValue)
    }
}

private enum TransferVerificationOpenFailureContext {
    case parentOpen
    case postInspectionOpen

    func classify(_ rawValue: Int32) -> TransferVerificationManifestError {
        switch self {
        case .parentOpen:
            TransferVerificationPOSIXErrorClassifier.parentOpenFailure(rawValue)
        case .postInspectionOpen:
            TransferVerificationPOSIXErrorClassifier.postInspectionOpenFailure(rawValue)
        }
    }
}

private let transferVerificationDirectoryOpenFlags =
    O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | O_DIRECTORY
private let transferVerificationRegularOpenFlags =
    O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC

func transferVerificationDuplicateDescriptor(_ descriptor: Int32) -> Int32 {
    Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
}

private func transferVerificationCheckTaskCancellation() throws {
    guard !Task.isCancelled else {
        throw TransferVerificationManifestError.cancelled
    }
}

private func transferVerificationKind(
    of information: stat
) throws -> TransferVerificationEntryKind {
    switch information.st_mode & S_IFMT {
    case S_IFREG:
        return .regularFile
    case S_IFDIR:
        return .directory
    case S_IFLNK:
        return .symbolicLink
    default:
        throw TransferVerificationManifestError.unsupportedItem
    }
}

private func transferVerificationOpen(
    path: [UInt8],
    flags: Int32,
    failureContext: TransferVerificationOpenFailureContext
) throws -> Int32 {
    let descriptor = transferVerificationWithCString(path) {
        Darwin.open($0, flags)
    }
    guard descriptor >= 0 else {
        throw failureContext.classify(errno)
    }
    return descriptor
}

private func transferVerificationOpenAt(
    _ parentDescriptor: Int32,
    name: [UInt8],
    flags: Int32,
    failureContext: TransferVerificationOpenFailureContext
) throws -> Int32 {
    let descriptor = transferVerificationWithCString(name) {
        Darwin.openat(parentDescriptor, $0, flags)
    }
    guard descriptor >= 0 else {
        throw failureContext.classify(errno)
    }
    return descriptor
}

private func transferVerificationFstat(_ descriptor: Int32) throws -> stat {
    var information = stat()
    guard Darwin.fstat(descriptor, &information) == 0 else {
        throw TransferVerificationManifestError.readFailed
    }
    return information
}

private func transferVerificationStatAt(
    _ parentDescriptor: Int32,
    name: [UInt8],
    flags: Int32,
    changeMeansChanged: Bool
) throws -> stat {
    var information = stat()
    let status = transferVerificationWithCString(name) {
        Darwin.fstatat(parentDescriptor, $0, &information, flags)
    }
    guard status == 0 else {
        let failure = errno
        throw changeMeansChanged
            ? TransferVerificationPOSIXErrorClassifier.namespaceFailure(failure)
            : TransferVerificationManifestError.readFailed
    }
    return information
}

enum TransferVerificationDirectoryNameCollector {
    static func collect(
        maximumNames: Int,
        next: () throws -> [UInt8]?,
        checkCancellation: () throws -> Void
    ) throws -> [[UInt8]] {
        guard maximumNames >= 0 else {
            throw TransferVerificationManifestError.scopeTooLarge
        }
        var names: [[UInt8]] = []
        while true {
            try checkCancellation()
            guard let rawName = try next() else { break }
            try checkCancellation()
            if rawName == [UInt8(ascii: ".")]
                || rawName == [UInt8(ascii: "."), UInt8(ascii: ".")]
            {
                continue
            }
            guard !rawName.isEmpty, !rawName.contains(0) else {
                throw TransferVerificationManifestError.unsupportedName
            }
            guard names.count < maximumNames else {
                throw TransferVerificationManifestError.scopeTooLarge
            }
            names.append(rawName)
        }
        try checkCancellation()
        names.sort { lhs, rhs in
            lhs.lexicographicallyPrecedes(rhs)
        }
        try checkCancellation()
        return names
    }
}

private func transferVerificationDirectoryNamesCore(
    _ descriptor: Int32,
    maximumNames: Int,
    cancellation: TransferVerificationCancellationState,
    descriptorLifecycle: TransferVerificationDescriptorLifecycle,
    onDuplicate: (@Sendable (Int32) -> Void)?
) throws -> [[UInt8]] {
    let duplicate = Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
    guard duplicate >= 0 else { throw TransferVerificationManifestError.readFailed }
    #if DEBUG
    let duplicateOwner = descriptorLifecycle.own(
        duplicate,
        role: .enumerationDuplicate
    )
    #else
    let duplicateOwner = descriptorLifecycle.own(duplicate)
    #endif
    defer { duplicateOwner.close() }
    #if DEBUG
    onDuplicate?(duplicate)
    #endif
    let directory = try duplicateOwner.transferToDirectoryStream()
    defer { directory.close() }
    return try TransferVerificationDirectoryNameCollector.collect(
        maximumNames: maximumNames,
        next: {
            try directory.withDirectory { directory in
                errno = 0
                guard let entry = Darwin.readdir(directory) else {
                    guard errno == 0 else {
                        throw TransferVerificationManifestError.readFailed
                    }
                    return nil
                }
                var rawNameTuple = entry.pointee.d_name
                return withUnsafeBytes(of: &rawNameTuple) { bytes -> [UInt8] in
                    Array(bytes.prefix { $0 != 0 })
                }
            }
        },
        checkCancellation: cancellation.check
    )
}

#if DEBUG
private func transferVerificationDirectoryNames(
    _ descriptor: Int32,
    maximumNames: Int,
    cancellation: TransferVerificationCancellationState,
    descriptorLifecycle: TransferVerificationDescriptorLifecycle,
    onDuplicate: (@Sendable (Int32) -> Void)?
) throws -> [[UInt8]] {
    try transferVerificationDirectoryNamesCore(
        descriptor,
        maximumNames: maximumNames,
        cancellation: cancellation,
        descriptorLifecycle: descriptorLifecycle,
        onDuplicate: onDuplicate
    )
}
#endif

private func transferVerificationDirectoryNames(
    _ descriptor: Int32,
    maximumNames: Int,
    cancellation: TransferVerificationCancellationState,
    descriptorLifecycle: TransferVerificationDescriptorLifecycle
) throws -> [[UInt8]] {
    try transferVerificationDirectoryNamesCore(
        descriptor,
        maximumNames: maximumNames,
        cancellation: cancellation,
        descriptorLifecycle: descriptorLifecycle,
        onDuplicate: nil
    )
}

private func transferVerificationReadLink(
    in parentDescriptor: Int32,
    name: [UInt8]
) throws -> [UInt8] {
    var capacity = 256
    let maximumCapacity = 1 << 20
    while capacity <= maximumCapacity {
        var buffer = [UInt8](repeating: 0, count: capacity)
        let count: Int = buffer.withUnsafeMutableBytes { bytes in
            transferVerificationWithCString(name) {
                Darwin.readlinkat(
                    parentDescriptor,
                    $0,
                    bytes.baseAddress!.assumingMemoryBound(to: CChar.self),
                    bytes.count
                )
            }
        }
        guard count >= 0 else {
            throw TransferVerificationPOSIXErrorClassifier.readLinkFailure(errno)
        }
        if count < capacity {
            return Array(buffer.prefix(count))
        }
        capacity *= 2
    }
    throw TransferVerificationManifestError.readFailed
}

private func transferVerificationWithCString<T>(
    _ bytes: [UInt8],
    body: (UnsafePointer<CChar>) -> T
) -> T {
    precondition(!bytes.isEmpty && !bytes.contains(0))
    var terminated = bytes + [0]
    return terminated.withUnsafeMutableBytes {
        body($0.baseAddress!.assumingMemoryBound(to: CChar.self))
    }
}
