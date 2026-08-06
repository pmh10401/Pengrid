import Foundation
import Testing
@testable import BloomFileManager

@Suite("ProtectedZIPModelTests")
struct ProtectedZIPModelTests {
    @Test func protectedCompressionPlanCarriesOnlyProtectionMetadata() throws {
        let root = URL(filePath: "/tmp/protected-zip-model-tests")
        let source = fixtureItem(named: "자료", in: root)
        let plan = try #require(ArchiveDestinationPlanner.compression(
            selectedItems: [source],
            in: root,
            occupiedNames: [],
            format: .zip,
            protection: .aes256
        ))

        #expect(plan.protection == .aes256)
        #expect(String(reflecting: plan).contains("password") == false)
        #expect(String(reflecting: plan).contains("ArchiveSecret") == false)

        let request = try #require(plan.requests(
            for: [IdentifiedFileRequest(
                url: source.url,
                identity: FileIdentity(
                    entryIdentifier: "source-entry",
                    resolvedIdentifier: "source-resolved"
                )
            )],
            destinationParentIdentity: FileIdentity(
                entryIdentifier: "parent-entry",
                resolvedIdentifier: "parent-resolved"
            )
        )?.first)
        #expect(request.protection == .aes256)
        #expect(String(reflecting: request).contains("password") == false)
    }

    @Test func protectedCompressionRejectsNonZIPFormats() {
        let root = URL(filePath: "/tmp/protected-zip-model-tests")
        let source = fixtureItem(named: "자료", in: root)

        #expect(ArchiveDestinationPlanner.compression(
            selectedItems: [source],
            in: root,
            occupiedNames: [],
            format: .tar,
            protection: .aes256
        ) == nil)

        #expect(ArchiveDestinationPlanner.extraction(
            selectedItems: [fixtureItem(named: "자료.zip", in: root)],
            in: root,
            occupiedNames: [],
            protection: .aes256
        ) == nil)
    }

    @Test func protectedByteProgressClampsAndZeroOrNilTotalsAreIndeterminate() {
        let clamped = ArchiveOperationProgress(
            kind: .extract,
            currentDisplayName: "자료.zip",
            phase: .processingBytes(completedByteCount: 150, totalByteCount: 100)
        )
        let negative = ArchiveOperationProgress(
            kind: .extract,
            currentDisplayName: "자료.zip",
            phase: .processingBytes(completedByteCount: -5, totalByteCount: 100)
        )
        let zero = ArchiveOperationProgress(
            kind: .extract,
            currentDisplayName: "자료.zip",
            phase: .processingBytes(completedByteCount: 5, totalByteCount: 0)
        )
        let unknown = ArchiveOperationProgress(
            kind: .extract,
            currentDisplayName: "자료.zip",
            phase: .processingBytes(completedByteCount: 5, totalByteCount: nil)
        )

        #expect(ArchiveOperationProgress(
            kind: .extract,
            currentDisplayName: "자료.zip",
            phase: .processingBytes(completedByteCount: 50, totalByteCount: 100)
        ).fractionCompleted == 0.5)
        #expect(clamped.fractionCompleted == 1)
        #expect(negative.fractionCompleted == 0)
        #expect(zero.fractionCompleted == nil)
        #expect(unknown.fractionCompleted == nil)
    }

    @Test func protectedProgressUsesPositiveKnownTotalsOnly() {
        #expect(ProtectedZIPProgress(
            completedByteCount: 5,
            totalByteCount: 10
        ).fractionCompleted == 0.5)
        #expect(ProtectedZIPProgress(
            completedByteCount: 50,
            totalByteCount: 10
        ).fractionCompleted == 1)
        #expect(ProtectedZIPProgress(
            completedByteCount: -1,
            totalByteCount: 10
        ).fractionCompleted == 0)
        #expect(ProtectedZIPProgress(
            completedByteCount: 1,
            totalByteCount: 0
        ).fractionCompleted == nil)
        #expect(ProtectedZIPProgress(
            completedByteCount: 1,
            totalByteCount: nil
        ).fractionCompleted == nil)
    }

    @Test func passwordRequestsExposeOnlyPublicPurposeAndBasename() {
        let request = ArchivePasswordRequest(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            purpose: .extract,
            archiveBasename: "/private/자료.zip\n",
            previousAttemptFailed: true
        )

        #expect(request.archiveBasename == "자료.zip")
        #expect(request.purpose == .extract)
        #expect(request.previousAttemptFailed)
        #expect(String(reflecting: request).contains("password") == false)
        #expect(String(reflecting: request).contains("ArchiveSecret") == false)
    }

    @Test func protectedLimitsUseAuditedCapacityConstants() {
        #expect(ProtectedZIPLimits.maximumEntryCount == 100_000)
        #expect(ProtectedZIPLimits.minimumCapacityReserve == 512 * 1_024 * 1_024)
        let limits = ProtectedZIPLimits(
            maximumOutputByteCount: 10_000,
            capacityReserveByteCount: ProtectedZIPLimits.minimumCapacityReserve
        )
        #expect(limits.maximumOutputByteCount == 10_000)
    }

    @Test func protectedErrorsMapToRedactedEnglishAndKoreanCopy() {
        let errors: [ProtectedZIPError] = [
            .invalidPasswordInput,
            .incorrectPasswordOrDamagedData,
            .unsupportedEncryption,
            .unsupportedCompression,
            .malformedArchive,
            .unsafeEntry,
            .entryCountOverflow,
            .insufficientCapacity,
            .outputBudgetOverflow,
            .identityChanged,
            .cancelled,
            .recoveryRequired
        ]
        let sentinel = "public-secret-sentinel"

        #expect(ProtectedZIPStrings.message(
            for: .unsafeEntry,
            locale: Locale(identifier: "en")
        ) == "The archive contains an unsafe item.")
        #expect(ProtectedZIPStrings.message(
            for: .unsafeEntry,
            locale: Locale(identifier: "ko")
        ) == "압축 파일에 안전하지 않은 항목이 있습니다.")

        for error in errors {
            let english = ProtectedZIPStrings.message(for: error, locale: Locale(identifier: "en"))
            let korean = ProtectedZIPStrings.message(for: error, locale: Locale(identifier: "ko"))
            #expect(!english.isEmpty)
            #expect(!korean.isEmpty)
            #expect(english.contains(sentinel) == false)
            #expect(korean.contains(sentinel) == false)
            #expect(english.contains("raw") == false)
            #expect(korean.contains("raw") == false)
        }

        #expect(ProtectedZIPStrings.message(
            for: .unsafeEntry,
            locale: Locale(identifier: "ja")
        ) == "The archive contains an unsafe item.")
    }

    @Test func passwordValidationCopyNeverIncludesInput() {
        let validationStates: [ArchivePasswordValidationError] = [
            .empty,
            .invalidLength,
            .tooShort,
            .tooLong,
            .containsNull,
            .confirmationMismatch
        ]
        for state in validationStates {
            #expect(!ProtectedZIPStrings.message(
                for: state,
                locale: Locale(identifier: "en")
            ).isEmpty)
            #expect(!ProtectedZIPStrings.message(
                for: state,
                locale: Locale(identifier: "ko")
            ).isEmpty)
        }
    }

    @Test func diagnosticEventCarriesStableCountsAndNoFreeFormSecrets() {
        let event = ProtectedZIPDiagnosticEvent(
            category: .extraction,
            archiveBasename: "/private/자료.zip\n",
            duration: 1.25,
            succeededCount: 1,
            failedCount: 0,
            skippedCount: 0
        )

        #expect(event.archiveBasename == "자료.zip")
        #expect(event.succeededCount == 1)
        #expect(event.failedCount == 0)
        #expect(event.skippedCount == 0)
        #expect(String(reflecting: event).contains("message") == false)
        #expect(String(reflecting: event).contains("entry") == false)
        #expect(String(reflecting: event).contains("password") == false)
        #expect(String(reflecting: event).contains("upstream") == false)
    }

    private func fixtureItem(named name: String, in root: URL) -> FileItem {
        FileItem(
            url: root.appending(path: name),
            name: name,
            isDirectory: false,
            isPackage: false,
            modifiedAt: nil,
            byteSize: nil,
            typeDescription: "Fixture"
        )
    }
}
