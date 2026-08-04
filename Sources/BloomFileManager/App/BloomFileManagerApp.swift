import SwiftUI

enum AppIdentity {
    static let displayName = "Pengrid"
    static let executableName = "BloomFileManager"
    static let bundleIdentifier = "com.minho.BloomFileManager"
}

struct CloudRuntimeDependencies {
    let accessCoordinator: CloudLocationScopedAccessCoordinator
    let fileSystem: any FileSystemAccess
    let materializer: LiveCloudMaterializationService

    init(
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init(),
        fileSystem: any FileSystemAccess = LiveFileSystemAccess()
    ) {
        let sharedFileSystem = fileSystem
        self.accessCoordinator = accessCoordinator
        self.fileSystem = sharedFileSystem
        materializer = LiveCloudMaterializationService(
            fileSystem: sharedFileSystem,
            accessCoordinator: accessCoordinator
        )
    }

    func makeDirectoryListingService() -> LiveDirectoryListingService {
        LiveDirectoryListingService(accessCoordinator: accessCoordinator)
    }

    func makeDirectoryMonitor() -> LiveDirectoryMonitor {
        LiveDirectoryMonitor(accessCoordinator: accessCoordinator)
    }

    func makeFileOperationService() -> FileOperationService {
        FileOperationService(
            fileSystem: fileSystem,
            accessCoordinator: accessCoordinator
        )
    }

    func makeChecksumService() -> LiveChecksumService {
        LiveChecksumService(
            materializer: materializer,
            accessCoordinator: accessCoordinator
        )
    }

    func makeComparisonListingService() -> LiveComparisonListingService {
        LiveComparisonListingService(accessCoordinator: accessCoordinator)
    }

    func makeComparisonTreeMonitor() -> LiveComparisonTreeMonitor {
        LiveComparisonTreeMonitor(accessCoordinator: accessCoordinator)
    }
}

struct StorageInspectorRuntimeDependencies {
    let scanner: any StorageScanning
    let duplicates: any StorageDuplicateDetecting
    let fingerprints: any StorageEntryFingerprintReading
}

@main
struct BloomFileManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var quickLookController = QuickLookController()
    @State private var operationController: FileOperationController
    @State private var smartSearch: SmartSearchStore
    @State private var smartSearchRouter: SmartSearchActionRouter
    @State private var favorites = FavoritesStore()
    @State private var cloudLocations: CloudLocationsStore
    @State private var comparison: ComparisonCoordinator
    @State private var storage: StorageAnalysisStore
    @State private var storageCleanupController: StorageCleanupController
    @State private var workspace: WorkspaceState
    private let cloudDependencies: CloudRuntimeDependencies
    private let storageDependencies: StorageInspectorRuntimeDependencies
    private let cloudWorkspaceActions: LiveCloudLocationWorkspaceActions

    init() {
        let cloudDependencies = CloudRuntimeDependencies()
        self.cloudDependencies = cloudDependencies
        let persistence = WorkspacePersistence()
        cloudWorkspaceActions = LiveCloudLocationWorkspaceActions()
        _operationController = State(initialValue: FileOperationController(
            service: cloudDependencies.makeFileOperationService(),
            materializer: cloudDependencies.materializer
        ))
        _smartSearch = State(initialValue: SmartSearchStore(
            service: LocalSmartSearchService(
                fileSystem: cloudDependencies.fileSystem,
                scopedAccessCoordinator: cloudDependencies.accessCoordinator
            ),
            persistence: persistence
        ))
        _smartSearchRouter = State(initialValue: SmartSearchActionRouter(
            fileSystem: cloudDependencies.fileSystem,
            accessCoordinator: cloudDependencies.accessCoordinator
        ))
        let cloudLocations = CloudLocationsStore(
            accessCoordinator: cloudDependencies.accessCoordinator
        )
        _cloudLocations = State(initialValue: cloudLocations)
        _comparison = State(initialValue: ComparisonCoordinator(
            listings: cloudDependencies.makeComparisonListingService(),
            checksums: cloudDependencies.makeChecksumService(),
            monitor: cloudDependencies.makeComparisonTreeMonitor()
        ))
        let fingerprints: any StorageEntryFingerprintReading =
            LiveStorageEntryFingerprintReader()
        let storageDependencies = StorageInspectorRuntimeDependencies(
            scanner: LiveStorageScanService(
                listing: cloudDependencies.makeComparisonListingService()
            ),
            duplicates: LiveStorageDuplicateDetectionService(
                checksums: cloudDependencies.makeChecksumService(),
                fingerprints: fingerprints
            ),
            fingerprints: fingerprints
        )
        self.storageDependencies = storageDependencies
        _storage = State(initialValue: StorageAnalysisStore(
            scanner: storageDependencies.scanner,
            duplicates: storageDependencies.duplicates,
            locationPolicy: LiveStorageScanLocationPolicy(
                cloudLocations: cloudLocations
            )
        ))
        _storageCleanupController = State(initialValue: StorageCleanupController(
            fingerprints: storageDependencies.fingerprints
        ))

        let home = FileManager.default.homeDirectoryForCurrentUser
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? home
        let restored = persistence.restore(home: home, downloads: downloads)
        _workspace = State(initialValue: WorkspaceState(
            restored: restored,
            listingService: cloudDependencies.makeDirectoryListingService(),
            monitor: cloudDependencies.makeDirectoryMonitor(),
            persistence: persistence,
            leftFallbackURL: home,
            rightFallbackURL: downloads
        ))
    }

    var body: some Scene {
        WindowGroup(AppIdentity.displayName) {
            WorkspaceView(
                workspace: workspace,
                operationController: operationController,
                smartSearch: smartSearch,
                smartSearchRouter: smartSearchRouter,
                favorites: favorites,
                cloudLocations: cloudLocations,
                comparison: comparison,
                storage: storage,
                storageCleanupController: storageCleanupController,
                quickLookController: quickLookController,
                materializer: cloudDependencies.materializer,
                fileSystem: cloudDependencies.fileSystem,
                cloudWorkspaceActions: cloudWorkspaceActions,
                cloudAccessCoordinator: cloudDependencies.accessCoordinator
            )
            .task {
                try? await cloudLocations.scanInitially()
            }
        }
        .defaultSize(width: 1_180, height: 760)
        .commands {
            WorkspaceCommands(
                quickLookController: quickLookController,
                operationController: operationController,
                smartSearch: smartSearch,
                storage: storage,
                storageCleanupController: storageCleanupController,
                materializer: cloudDependencies.materializer,
                fileSystem: cloudDependencies.fileSystem,
                accessCoordinator: cloudDependencies.accessCoordinator
            )
        }

        Settings {
            TabView {
                CloudLocationsSettingsView(cloudLocations: cloudLocations)
                    .tabItem {
                        Label("Cloud Locations", systemImage: "externaldrive.badge.icloud")
                    }
            }
            .navigationTitle("\(AppIdentity.displayName) Settings")
        }
    }
}
