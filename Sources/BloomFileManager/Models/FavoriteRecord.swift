import Foundation

struct FavoriteRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var displayName: String
    var bookmarkData: Data
    var lastKnownPath: String
}

enum FavoriteResolution: Equatable, Sendable {
    case available(URL)
    case unavailable(lastKnownPath: String)
}
