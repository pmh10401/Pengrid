import Foundation

enum ArchiveFormat: CaseIterable, Hashable, Sendable, Equatable {
    case zip
    case tar
    case tarGzip
    case tarBzip2
    case tarXz

    var canonicalSuffix: String {
        switch self {
        case .zip: ".zip"
        case .tar: ".tar"
        case .tarGzip: ".tar.gz"
        case .tarBzip2: ".tar.bz2"
        case .tarXz: ".tar.xz"
        }
    }

    var displayName: String {
        switch self {
        case .zip: "ZIP"
        case .tar: "TAR"
        case .tarGzip: "TAR.GZ"
        case .tarBzip2: "TAR.BZ2"
        case .tarXz: "TAR.XZ"
        }
    }

    var accessibilityName: String {
        "\(displayName) archive"
    }

    var tarCompressionFlag: String? {
        switch self {
        case .zip: nil
        case .tar: nil
        case .tarGzip: "-z"
        case .tarBzip2: "-j"
        case .tarXz: "-J"
        }
    }

    static func detect(filename: String) -> ArchiveFormat? {
        recognizedSuffixes.first { filename.lowercased().hasSuffix($0.suffix) }?.format
    }

    static func removingRecognizedSuffix(from filename: String) -> String? {
        guard let suffix = recognizedSuffix(in: filename) else {
            return nil
        }
        return String(filename.dropLast(suffix.count))
    }

    static func recognizedSuffix(in filename: String) -> String? {
        guard let recognized = recognizedSuffixes.first(where: {
            filename.lowercased().hasSuffix($0.suffix)
        })?.suffix else {
            return nil
        }
        return String(filename.suffix(recognized.count))
    }

    private static let recognizedSuffixes: [(suffix: String, format: ArchiveFormat)] = [
        (".tar.bz2", .tarBzip2),
        (".tar.gz", .tarGzip),
        (".tar.xz", .tarXz),
        (".tbz", .tarBzip2),
        (".tbz2", .tarBzip2),
        (".tgz", .tarGzip),
        (".txz", .tarXz),
        (".tar", .tar),
        (".zip", .zip)
    ]
}
