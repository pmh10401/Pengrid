enum CloudItemAvailability: Hashable, Sendable {
    case availableLocally
    case onlineOnly
    case downloading(progress: Double?)
    case unavailable(CloudAvailabilityFailure)
    case unknown

    var requiresMaterialization: Bool {
        switch self {
        case .availableLocally: false
        case .onlineOnly, .downloading, .unavailable, .unknown: true
        }
    }
}

enum CloudAvailabilityFailure: Hashable, Sendable {
    case offline
    case insufficientLocalStorage
    case permissionDenied
    case itemChanged
    case providerFailure
}

enum CloudPreparationPurpose: Sendable {
    case open
    case quickLook
    case transfer
    case checksum
}
