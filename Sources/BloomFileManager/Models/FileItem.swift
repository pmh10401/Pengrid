import Foundation

struct FileItem: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isSymbolicLink: Bool
    let modifiedAt: Date?
    let byteSize: Int64?
    let typeDescription: String
    let availability: CloudItemAvailability

    init(
        url: URL,
        name: String,
        isDirectory: Bool,
        isPackage: Bool,
        isSymbolicLink: Bool = false,
        modifiedAt: Date?,
        byteSize: Int64?,
        typeDescription: String,
        availability: CloudItemAvailability = .availableLocally
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymbolicLink = isSymbolicLink
        self.modifiedAt = modifiedAt
        self.byteSize = byteSize
        self.typeDescription = typeDescription
        self.availability = availability
    }
}
