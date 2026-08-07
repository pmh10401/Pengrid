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

protocol ImmediateDirectoryEnumerator: AnyObject {
    func nextObject() -> Any?
}

extension FileManager.DirectoryEnumerator: ImmediateDirectoryEnumerator {}

struct LiveImmediateDirectoryEntryCursorFactory: ImmediateDirectoryEntryCursorFactory {
    private let makeEnumerator: @Sendable (
        URL,
        [URLResourceKey],
        FileManager.DirectoryEnumerationOptions,
        @escaping @Sendable (URL, Error) -> Bool
    ) -> (any ImmediateDirectoryEnumerator)?

    init() {
        makeEnumerator = { directory, keys, options, errorHandler in
            FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: keys,
                options: options,
                errorHandler: errorHandler
            )
        }
    }

    init(
        makeEnumerator: @escaping @Sendable (
            URL,
            [URLResourceKey],
            FileManager.DirectoryEnumerationOptions,
            @escaping @Sendable (URL, Error) -> Bool
        ) -> (any ImmediateDirectoryEnumerator)?
    ) {
        self.makeEnumerator = makeEnumerator
    }

    func makeCursor(
        in directory: URL,
        includingPropertiesForKeys keys: Set<URLResourceKey>,
        options: FileManager.DirectoryEnumerationOptions
    ) throws -> any ImmediateDirectoryEntryCursor {
        let errorBox = EnumerationErrorBox()
        guard let enumerator = makeEnumerator(
            directory,
            Array(keys),
            options.union(.skipsSubdirectoryDescendants),
            { _, error in
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
    private let enumerator: any ImmediateDirectoryEnumerator
    private let errorBox: EnumerationErrorBox

    init(enumerator: any ImmediateDirectoryEnumerator, errorBox: EnumerationErrorBox) {
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
