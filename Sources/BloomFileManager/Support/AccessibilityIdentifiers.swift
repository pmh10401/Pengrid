enum AccessibilityIdentifiers {
    static let placesRail = "placesRail"
    static let cloudSection = "cloudSection"
    static let cloudRescan = "cloud.rescan"
    static let cloudAddFolder = "cloud.addFolder"
    static let cloudSettings = "cloud.settings"
    static let cloudSettingsVisible = "cloud.settings.visible"
    static let cloudSettingsHidden = "cloud.settings.hidden"
    static let cloudSettingsRescan = "cloud.settings.rescan"
    static let favoritesSection = "favoritesSection"
    static let leftPane = "leftPane"
    static let rightPane = "rightPane"
    static let operationStatus = "operationStatus"
    static let conflictSheet = "conflictSheet"
    static let comparisonWorkspace = "comparisonWorkspace"
    static let comparisonToolbar = "comparisonToolbar"
    static let comparisonTable = "comparisonTable"
    static let comparisonStatusRail = "comparisonStatusRail"
    static let comparisonActionBar = "comparisonActionBar"
    static let comparisonMoveConfirmation = "comparisonMoveConfirmation"
    static let storageInspectorWorkspace = "storageInspector.workspace"
    static let storageInspectorToolbar = "storageInspector.toolbar"
    static let storageInspectorSidebar = "storageInspector.sidebar"
    static let storageInspectorResults = "storageInspector.results"
    static let storageInspectorDetail = "storageInspector.detail"
    static let storageInspectorReview = "storageInspector.review"
    static let storageInspectorChooseLocation = "storageInspector.chooseLocation"
    static let storageInspectorStart = "storageInspector.start"
    static let storageInspectorCancel = "storageInspector.cancel"
    static let storageInspectorScanAgain = "storageInspector.scanAgain"
    static let storageInspectorHiddenItems = "storageInspector.hiddenItems"
    static let storageInspectorExit = "storageInspector.exit"
    static let storageInspectorProgress = "storageInspector.progress"
    static let storageInspectorGroupNavigation = "storageInspector.groupNavigation"
    static let storageInspectorGroupMembers = "storageInspector.groupMembers"

    static func storageInspectorSection(_ section: StorageAnalysisSection) -> String {
        "storageInspector.section.\(section.rawValue)"
    }

    static func storageInspectorCategory(_ category: StorageFileCategory) -> String {
        "storageInspector.category.\(category.rawValue)"
    }

    static func cloudLocationRow(_ id: StorageLocationID) -> String {
        switch id {
        case let .fileProvider(domainIdentifier, rootIdentity):
            return [
                "cloud.location.fileProvider",
                domainIdentifier,
                rootIdentity.base64EncodedString()
            ].joined(separator: ".")
        case let .manualBookmark(id):
            return "cloud.location.manual.\(id.uuidString.lowercased())"
        }
    }

    static func cloudSettingsAction(
        _ action: CloudLocationsSettingsAction,
        locationID: StorageLocationID
    ) -> String {
        "cloud.settings.\(action.rawValue).\(cloudLocationRow(locationID))"
    }

    static func comparisonFilter(_ filter: ComparisonFilter) -> String {
        switch filter {
        case .differences: "comparisonFilter.differences"
        case .all: "comparisonFilter.all"
        case .leftOnly: "comparisonFilter.leftOnly"
        case .rightOnly: "comparisonFilter.rightOnly"
        case .contentChanged: "comparisonFilter.contentChanged"
        case .errors: "comparisonFilter.errors"
        }
    }
}

enum PaneAccessibilityPresentation {
    static func label(for paneID: PaneID) -> String {
        switch paneID {
        case .left: "Left file pane"
        case .right: "Right file pane"
        }
    }

    static func value(isActive: Bool) -> String {
        isActive ? "Active pane" : "Inactive pane"
    }
}

enum AccessibilityMotionPresentation {
    static func allowsNonessentialAnimation(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }
}
