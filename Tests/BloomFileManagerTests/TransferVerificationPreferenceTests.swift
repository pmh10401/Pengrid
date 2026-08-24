import Foundation
import Testing
@testable import BloomFileManager

@MainActor
@Suite struct TransferVerificationPreferenceTests {
    @Test func missingAndMalformedStorageDefaultToDisabledWithoutWriting() {
        let missing = InMemoryTransferVerificationPreferencePersistence()
        let missingPreference = TransferVerificationPreference(persistence: missing)

        #expect(missingPreference.isEnabled == false)
        #expect(missingPreference.policy == .disabled)
        #expect(missing.savedValues.isEmpty)

        let malformed = InMemoryTransferVerificationPreferencePersistence(
            loadedValue: nil,
            representsMalformedStorage: true
        )
        let malformedPreference = TransferVerificationPreference(persistence: malformed)

        #expect(malformedPreference.isEnabled == false)
        #expect(malformedPreference.policy == .disabled)
        #expect(malformed.savedValues.isEmpty)
    }

    @Test func trueAndFalseRoundTripsPersistAndEnabledPolicyUsesExactlyTwoPairs() {
        let persistence = InMemoryTransferVerificationPreferencePersistence(
            loadedValue: false
        )
        let preference = TransferVerificationPreference(persistence: persistence)

        preference.isEnabled = true
        #expect(persistence.savedValues == [true])
        #expect(preference.policy == .sha256(maxConcurrentPairs: 2))
        #expect(preference.policy.effectivePairLimit == 2)

        let restoredEnabled = TransferVerificationPreference(persistence: persistence)
        #expect(restoredEnabled.isEnabled)
        #expect(restoredEnabled.policy == .sha256(maxConcurrentPairs: 2))

        restoredEnabled.isEnabled = false
        #expect(persistence.savedValues == [true, false])
        let restoredDisabled = TransferVerificationPreference(persistence: persistence)
        #expect(restoredDisabled.isEnabled == false)
        #expect(restoredDisabled.policy == .disabled)
    }

    @Test func userDefaultsPersistenceUsesOnlyTheTypedVersionedBooleanKey() throws {
        let suiteName = "TransferVerificationPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = UserDefaultsTransferVerificationPreferencePersistence(
            defaults: defaults
        )

        defaults.set("not-a-boolean", forKey: persistence.key)
        #expect(persistence.loadEnabled() == nil)
        #expect(TransferVerificationPreference(persistence: persistence).isEnabled == false)

        persistence.saveEnabled(true)
        #expect(defaults.object(forKey: persistence.key) as? Bool == true)
        #expect(persistence.loadEnabled() == true)
        #expect(persistence.key == "fileOperations.verifyTransferredContents.v1")
    }
}

@MainActor
private final class InMemoryTransferVerificationPreferencePersistence:
    TransferVerificationPreferencePersisting
{
    private var storedValue: Bool?
    private let representsMalformedStorage: Bool
    private(set) var savedValues: [Bool] = []

    init(
        loadedValue: Bool? = nil,
        representsMalformedStorage: Bool = false
    ) {
        storedValue = loadedValue
        self.representsMalformedStorage = representsMalformedStorage
    }

    func loadEnabled() -> Bool? {
        representsMalformedStorage ? nil : storedValue
    }

    func saveEnabled(_ enabled: Bool) {
        storedValue = enabled
        savedValues.append(enabled)
    }
}
