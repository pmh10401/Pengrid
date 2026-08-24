import Foundation
import Observation

@MainActor
protocol TransferVerificationPreferencePersisting {
    func loadEnabled() -> Bool?
    func saveEnabled(_ enabled: Bool)
}

@MainActor
struct UserDefaultsTransferVerificationPreferencePersistence:
    TransferVerificationPreferencePersisting
{
    let key = "fileOperations.verifyTransferredContents.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadEnabled() -> Bool? {
        defaults.object(forKey: key) as? Bool
    }

    func saveEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: key)
    }
}

@MainActor @Observable
final class TransferVerificationPreference {
    private let persistence: any TransferVerificationPreferencePersisting

    var isEnabled: Bool {
        didSet { persistence.saveEnabled(isEnabled) }
    }

    var policy: TransferVerificationPolicy {
        isEnabled ? .sha256(maxConcurrentPairs: 2) : .disabled
    }

    init(
        persistence: any TransferVerificationPreferencePersisting =
            UserDefaultsTransferVerificationPreferencePersistence()
    ) {
        self.persistence = persistence
        isEnabled = persistence.loadEnabled() ?? false
    }
}
