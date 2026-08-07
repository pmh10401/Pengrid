import Foundation

protocol ImmediateDirectoryEntryCursor: AnyObject {
    func next() throws -> URL?
}

protocol ImmediateDirectoryEntryCursorFactory: Sendable {
    func makeCursor(
        in directory: URL,
        includingPropertiesForKeys keys: Set<URLResourceKey>,
        options: FileManager.DirectoryEnumerationOptions
    ) throws -> any ImmediateDirectoryEntryCursor
}

struct LiveImmediateDirectoryEntryCursorFactory: ImmediateDirectoryEntryCursorFactory {
    func makeCursor(
        in directory: URL,
        includingPropertiesForKeys keys: Set<URLResourceKey>,
        options: FileManager.DirectoryEnumerationOptions
    ) throws -> any ImmediateDirectoryEntryCursor {
        let errorBox = EnumerationErrorBox()
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: options.union(.skipsSubdirectoryDescendants),
            errorHandler: { _, error in
                errorBox.capture(error)
                return false
            }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        return LiveImmediateDirectoryEntryCursor(enumerator: enumerator, errorBox: errorBox)
    }
}

private final class LiveImmediateDirectoryEntryCursor: ImmediateDirectoryEntryCursor {
    private let enumerator: FileManager.DirectoryEnumerator
    private let errorBox: EnumerationErrorBox

    init(enumerator: FileManager.DirectoryEnumerator, errorBox: EnumerationErrorBox) {
        self.enumerator = enumerator
        self.errorBox = errorBox
    }

    func next() throws -> URL? {
        if let error = errorBox.error {
            throw error
        }
        guard let object = enumerator.nextObject() else {
            if let error = errorBox.error {
                throw error
            }
            return nil
        }
        guard let url = object as? URL else {
            throw ImmediateDirectoryEntryCursorError.unexpectedEnumeratorObject
        }
        if let error = errorBox.error {
            throw error
        }
        return url
    }
}

private final class EnumerationErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    var error: Error? {
        lock.withLock { storedError }
    }

    func capture(_ error: Error) {
        lock.withLock {
            storedError = error
        }
    }
}

private enum ImmediateDirectoryEntryCursorError: Error {
    case unexpectedEnumeratorObject
}
