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

@MainActor
private final class WorkspacePreviewCloseBinding {
    weak var previewCoordinator: WorkspacePreviewCoordinator?

    func closePreview() {
        previewCoordinator?.closeAndRestoreFocus()
    }
}

@main
struct BloomFileManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var quickLookController: QuickLookController
    @State private var previewCoordinator: WorkspacePreviewCoordinator
    @State private var operationController: FileOperationController
    @State private var batchRename: BatchRenameModel
    @State private var passwordCoordinator: ArchivePasswordPromptCoordinator
    @State private var smartSearch: SmartSearchStore
    @State private var smartSearchRouter: SmartSearchActionRouter
    @State private var getInfoInspector: GetInfoInspectorController
    @State private var favorites = FavoritesStore()
    @State private var cloudLocations: CloudLocationsStore
    @State private var comparison: ComparisonCoordinator
    @State private var storage: StorageAnalysisStore
    @State private var storageCleanupController: StorageCleanupController
    @State private var workspaceSession: WorkspaceSessionState
    @State private var contextActionRouter: FileContextActionRouter
    @State private var openWithProvider: OpenWithApplicationProvider
    @State private var selectionFolder: SelectionFolderModel
    private let cloudDependencies: CloudRuntimeDependencies
    private let storageDependencies: StorageInspectorRuntimeDependencies
    private let cloudWorkspaceActions: LiveCloudLocationWorkspaceActions

    init() {
        let quickLookController = QuickLookController()
        _quickLookController = State(initialValue: quickLookController)
        let cloudDependencies = CloudRuntimeDependencies()
        self.cloudDependencies = cloudDependencies
        let persistence = WorkspacePersistence()
        cloudWorkspaceActions = LiveCloudLocationWorkspaceActions()
        let passwordCoordinator = ArchivePasswordPromptCoordinator()
        _passwordCoordinator = State(initialValue: passwordCoordinator)
        let operationService = cloudDependencies.makeFileOperationService()
        let archiveService = operationService.makeRoutingArchiveOperationService(
            passwordProvider: passwordCoordinator
        )
        let operationController = FileOperationController(
            service: operationService,
            materializer: cloudDependencies.materializer,
            archiveService: archiveService
        )
        _operationController = State(initialValue: operationController)
        _contextActionRouter = State(initialValue: FileContextActionRouter(
            fileSystem: cloudDependencies.fileSystem,
            accessCoordinator: cloudDependencies.accessCoordinator,
            materializer: cloudDependencies.materializer
        ))
        _openWithProvider = State(initialValue: OpenWithApplicationProvider())
        _selectionFolder = State(initialValue: SelectionFolderModel(
            fileSystem: cloudDependencies.fileSystem,
            accessCoordinator: cloudDependencies.accessCoordinator
        ))
        _batchRename = State(initialValue: BatchRenameModel(
            fileSystem: cloudDependencies.fileSystem,
            accessCoordinator: cloudDependencies.accessCoordinator
        ))
        let localSearch = LocalSmartSearchService(
            fileSystem: cloudDependencies.fileSystem,
            scopedAccessCoordinator: cloudDependencies.accessCoordinator
        )
        let spotlightSearch = LiveSpotlightSmartSearchService(
            runner: LiveSpotlightMetadataQueryRunner(),
            fileSystem: cloudDependencies.fileSystem,
            availabilityReader: LiveCloudItemAvailabilityService(),
            scopedAccessCoordinator: cloudDependencies.accessCoordinator
        )
        let searchService = ContentAwareSmartSearchService(
            local: localSearch,
            spotlight: spotlightSearch
        )
        _smartSearch = State(initialValue: SmartSearchStore(
            service: searchService,
            persistence: persistence
        ))
        let getInfoModel = GetInfoInspectorModel(
            inspector: LiveGetInfoInspectionService(
                fileSystem: cloudDependencies.fileSystem,
                accessCoordinator: cloudDependencies.accessCoordinator
            ),
            checksumService: cloudDependencies.makeChecksumService()
        )
        _getInfoInspector = State(initialValue: GetInfoInspectorController(model: getInfoModel))
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
        let sessionPersistence = WorkspaceSessionPersistence()
        let restoredSession = sessionPersistence.restore(
            legacy: persistence.load(),
            home: home,
            downloads: downloads,
            isDirectory: { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(
                    atPath: url.path,
                    isDirectory: &isDirectory
                ) && isDirectory.boolValue
            }
        )
        let workspaceSession = WorkspaceSessionState(
            restored: restoredSession,
            persistence: sessionPersistence,
            runtimeFactory: WorkspaceRuntimeFactory(
                listingServiceFactory: { cloudDependencies.makeDirectoryListingService() },
                monitorFactory: { cloudDependencies.makeDirectoryMonitor() }
            )
        )
        _workspaceSession = State(initialValue: workspaceSession)

        let previewCloseBinding = WorkspacePreviewCloseBinding()
        let folderPreviewModel = FolderPreviewModel(
            listing: LiveFolderPreviewListing(fileSystem: cloudDependencies.fileSystem)
        )
        let folderPreviewController = FolderPreviewController(
            model: folderPreviewModel,
            onClose: { previewCloseBinding.closePreview() }
        )
        let previewCoordinator = WorkspacePreviewCoordinator(
            fileSystem: cloudDependencies.fileSystem,
            quickLookController: quickLookController,
            folderPresenter: folderPreviewController,
            materializer: cloudDependencies.materializer,
            restoreFocus: { workspaceSession.activeWorkspace.activePane.requestTableFocus() }
        )
        previewCloseBinding.previewCoordinator = previewCoordinator
        _previewCoordinator = State(initialValue: previewCoordinator)

        // Register the exact controller/coordinator instances before the
        // SwiftUI scene can dispatch any user work or AppKit Quit requests.
        appDelegate.configureTermination(
            operationController: operationController,
            passwordCoordinator: passwordCoordinator
        )
    }

    var body: some Scene {
        WindowGroup(AppIdentity.displayName) {
            WorkspaceView(
                workspaceSession: workspaceSession,
                operationController: operationController,
                batchRename: batchRename,
                smartSearch: smartSearch,
                smartSearchRouter: smartSearchRouter,
                favorites: favorites,
                cloudLocations: cloudLocations,
                comparison: comparison,
                storage: storage,
                storageCleanupController: storageCleanupController,
                quickLookController: quickLookController,
                previewCoordinator: previewCoordinator,
                materializer: cloudDependencies.materializer,
                fileSystem: cloudDependencies.fileSystem,
                cloudWorkspaceActions: cloudWorkspaceActions,
                cloudAccessCoordinator: cloudDependencies.accessCoordinator,
                passwordCoordinator: passwordCoordinator,
                contextActionRouter: contextActionRouter,
                openWithProvider: openWithProvider,
                selectionFolder: selectionFolder,
                getInfoInspector: getInfoInspector
            )
            .task {
                try? await cloudLocations.scanInitially()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                workspaceSession.flushPersistence()
            }
        }
        .defaultSize(width: 1_180, height: 760)
        .commands {
            WorkspaceCommands(
                quickLookController: quickLookController,
                previewCoordinator: previewCoordinator,
                operationController: operationController,
                contextActionRouter: contextActionRouter,
                openWithProvider: openWithProvider,
                selectionFolder: selectionFolder,
                smartSearch: smartSearch,
                getInfoInspector: getInfoInspector,
                storage: storage,
                storageCleanupController: storageCleanupController,
                materializer: cloudDependencies.materializer,
                fileSystem: cloudDependencies.fileSystem,
                accessCoordinator: cloudDependencies.accessCoordinator,
                batchRename: batchRename,
                cloudLocations: cloudLocations
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
