import Foundation
import Darwin

protocol ShelfPersisting: Sendable {
    func load() async throws -> [ShelfItem]
    func save(_ items: [ShelfItem]) async throws
    func remove() async throws
}

actor ShelfPersistence: ShelfPersisting {
    let root: URL
    private let filename = "snapshot.plist"
    private let maximumSnapshotBytes = 66 * 1024 * 1024
    private struct Snapshot: Codable { let version: Int; let items: [ShelfItem] }
    private enum StorageError: Error, LocalizedError {
        case unsafePath, invalidSnapshot, io
        var errorDescription: String? {
            switch self {
            case .unsafePath: "The shelf storage path is not a private, regular location."
            case .invalidSnapshot: "The saved shelf is damaged, too large, or from an unsupported version."
            case .io: "The shelf could not access its local snapshot. Check available disk space and permissions."
            }
        }
    }
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pengrid/TopShelf", isDirectory: true)
    }
    init(root: URL) { self.root = root }

    func load() throws -> [ShelfItem] {
        guard let directory = try openDirectory(create: false) else { return [] }
        defer { close(directory) }
        guard try checkSnapshot(in: directory) else { return [] }
        let descriptor = openat(directory, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw StorageError.io }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, isPrivateFile(info),
              info.st_size > 0, info.st_size <= maximumSnapshotBytes else { throw StorageError.invalidSnapshot }
        // A bounded read, not a mapped file: another writer cannot enlarge the allocation.
        var data = Data(count: Int(info.st_size))
        let count = data.count
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let amount = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), count - offset)
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw StorageError.io }
                offset += amount
            }
        }
        let snapshot = try PropertyListDecoder().decode(Snapshot.self, from: data)
        guard snapshot.version == 1, snapshot.items.count <= ShelfItem.maximumItemCount else {
            throw StorageError.invalidSnapshot
        }
        return try ShelfItem.validatedAddition(snapshot.items, to: [])
    }

    func save(_ items: [ShelfItem]) throws {
        try Task.checkCancellation()
        let validated = try ShelfItem.validatedAddition(items, to: [])
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(Snapshot(version: 1, items: validated))
        try Task.checkCancellation()
        guard data.count <= maximumSnapshotBytes else { throw StorageError.invalidSnapshot }
        guard let directory = try openDirectory(create: true) else { throw StorageError.io }
        defer { close(directory) }
        _ = try checkSnapshot(in: directory)
        let temporary = ".snapshot-\(UUID().uuidString).tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw StorageError.io }
        defer { close(descriptor); unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let amount = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw StorageError.io }
                offset += amount
            }
        }
        guard fsync(descriptor) == 0 else { throw StorageError.io }
        _ = try checkSnapshot(in: directory)
        try Task.checkCancellation()
        guard renameat(directory, temporary, directory, filename) == 0 else { throw StorageError.io }
    }

    func remove() throws {
        try Task.checkCancellation()
        guard let directory = try openDirectory(create: false) else { return }
        defer { close(directory) }
        guard try checkSnapshot(in: directory) else { return }
        guard unlinkat(directory, filename, 0) == 0 || errno == ENOENT else { throw StorageError.io }
    }

    private func openDirectory(create: Bool) throws -> Int32? {
        // Resolve only macOS's system aliases; never resolve an app-owned component.
        var path = root.standardizedFileURL.path
        if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") { path = "/private" + path }
        guard root.isFileURL, path.hasPrefix("/"), path != "/" else { throw StorageError.unsafePath }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw StorageError.io }
        for component in path.split(separator: "/").map(String.init) {
            var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 && errno == ENOENT && create {
                guard mkdirat(descriptor, component, 0o700) == 0 || errno == EEXIST else {
                    close(descriptor)
                    throw StorageError.io
                }
                next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            if next < 0 {
                let absent = errno == ENOENT
                close(descriptor)
                if !create && absent { return nil }
                throw StorageError.unsafePath
            }
            close(descriptor)
            descriptor = next
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
              fchmod(descriptor, 0o700) == 0 else {
            close(descriptor)
            throw StorageError.unsafePath
        }
        return descriptor
    }

    private func isPrivateFile(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid() && info.st_nlink == 1
    }

    private func checkSnapshot(in directory: Int32) throws -> Bool {
        var info = stat()
        guard fstatat(directory, filename, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return false }
            throw StorageError.io
        }
        guard isPrivateFile(info) else { throw StorageError.unsafePath }
        return true
    }
}
