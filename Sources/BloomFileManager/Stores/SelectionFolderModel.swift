import Foundation
import Observation

@MainActor @Observable
final class SelectionFolderModel {
    static let defaultFolderName = "New Folder with Items"

    private(set) var snapshot: ContextActionSnapshot?
    private(set) var validationMessage: String?
    var folderName = defaultFolderName {
        didSet { validateCurrentName() }
    }
    private(set) var isPresented = false

    var canSubmit: Bool {
        isPresented
            && hasValidatedCapture
            && !isPreparing
            && validationMessage == nil
            && snapshot != nil
    }

    @ObservationIgnored private let fileSystem: any FileSystemAccess
    @ObservationIgnored private let accessCoordinator: CloudLocationScopedAccessCoordinator
    @ObservationIgnored private var occupiedNames: Set<String> = []
    @ObservationIgnored private var comparisonPolicy: FilenameComparisonPolicy = .caseSensitiveCanonical
    @ObservationIgnored private var hasValidatedCapture = false
    @ObservationIgnored private var isPreparing = false
    @ObservationIgnored private var generation: UInt64 = 0

    init(
        fileSystem: any FileSystemAccess = LiveFileSystemAccess(),
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init()
    ) {
        self.fileSystem = fileSystem
        self.accessCoordinator = accessCoordinator
    }

    func present(_ snapshot: ContextActionSnapshot) async {
        generation &+= 1
        let presentationGeneration = generation
        folderName = Self.defaultFolderName
        self.snapshot = snapshot
        isPresented = true
        isPreparing = true
        validationMessage = nil
        occupiedNames = []
        comparisonPolicy = .caseSensitiveCanonical
        hasValidatedCapture = false

        guard snapshot.sourceCapability == .writable else {
            fail("This location does not allow local file operations.")
            return
        }
        guard snapshot.sources.count >= 2 else {
            fail("Select at least two items.")
            return
        }

        let parentURL = snapshot.sourceDirectory.url.standardizedFileURL
        guard snapshot.sources.allSatisfy({
            $0.item.url.deletingLastPathComponent().standardizedFileURL == parentURL
        }) else {
            fail("Every selected item must be in the same folder.")
            return
        }

        let leases: [CloudLocationScopedAccessLease]
        do {
            leases = try accessCoordinator.acquireAccess(
                for: [parentURL] + snapshot.sources.map(\.item.url)
            )
        } catch {
            fail("The selected folder is not currently accessible.")
            return
        }
        defer { leases.forEach { $0.finish() } }

        do {
            guard let currentParentIdentity = try await fileSystem.identity(of: parentURL) else {
                guard isCurrent(presentationGeneration) else { return }
                fail("The containing folder is no longer available.")
                return
            }
            guard isCurrent(presentationGeneration) else { return }
            guard currentParentIdentity == snapshot.sourceDirectory.identity else {
                fail("The containing folder has changed.")
                return
            }

            for source in snapshot.sources {
                guard let currentIdentity = try await fileSystem.identity(of: source.item.url) else {
                    guard isCurrent(presentationGeneration) else { return }
                    fail("\(source.item.name) is no longer available.")
                    return
                }
                guard isCurrent(presentationGeneration) else { return }
                guard currentIdentity == source.identity else {
                    fail("\(source.item.name) has changed.")
                    return
                }
            }

            let policy = try await fileSystem.filenameComparisonPolicy(in: parentURL)
            guard isCurrent(presentationGeneration) else { return }
            let names = try await fileSystem.names(in: parentURL)
            guard isCurrent(presentationGeneration) else { return }

            comparisonPolicy = policy
            occupiedNames = names
            isPreparing = false
            hasValidatedCapture = true
            validateCurrentName()
        } catch is CancellationError {
            guard presentationGeneration == generation else { return }
            dismiss()
        } catch {
            guard isCurrent(presentationGeneration) else { return }
            fail("The selected folder is not currently accessible.")
        }
    }

    func updateName(_ value: String) {
        guard isPresented else { return }
        folderName = value
    }

    func beginSubmission() -> SelectionFolderPlan? {
        guard canSubmit, let snapshot else { return nil }
        let normalizedName = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return SelectionFolderPlan(
            parentURL: snapshot.sourceDirectory.url.standardizedFileURL,
            parentIdentity: snapshot.sourceDirectory.identity,
            folderName: normalizedName,
            folderURL: snapshot.sourceDirectory.url.appending(path: normalizedName),
            sources: snapshot.sources
        )
    }

    func dismiss() {
        generation &+= 1
        snapshot = nil
        validationMessage = nil
        occupiedNames = []
        hasValidatedCapture = false
        isPreparing = false
        isPresented = false
    }

    private func isCurrent(_ presentationGeneration: UInt64) -> Bool {
        presentationGeneration == generation && isPresented
    }

    private func fail(_ message: String) {
        hasValidatedCapture = false
        isPreparing = false
        validationMessage = message
    }

    private func validateCurrentName() {
        guard isPresented, !isPreparing else { return }
        let normalizedName = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try FilenameValidator.validate(normalizedName)
        } catch FilenameError.empty {
            validationMessage = "Enter a folder name."
            return
        } catch FilenameError.dotEntry {
            validationMessage = "A folder name cannot be . or ..."
            return
        } catch FilenameError.containsPathSeparator {
            validationMessage = "A folder name cannot contain a slash."
            return
        } catch FilenameError.containsNUL {
            validationMessage = "A folder name cannot contain a NUL character."
            return
        } catch {
            validationMessage = error.localizedDescription
            return
        }

        if occupiedNames.contains(where: { comparisonPolicy.key(for: $0) == comparisonPolicy.key(for: normalizedName) }) {
            validationMessage = "A folder with that name already exists."
            return
        }
        validationMessage = nil
    }
}
