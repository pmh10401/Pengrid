import Foundation

enum WorkspaceSessionAccessibilityIdentifiers {
    static let tabBar = "workspaceTabs.bar"
    static let newTab = "workspaceTabs.new"
    static let profiles = "workspaceTabs.profiles"
    static let profilesSheet = "workspaceProfiles.sheet"
    static let saveProfile = "workspaceProfiles.save"
    static let manageProfiles = "workspaceProfiles.manage"

    static func tab(_ id: WorkspaceTabID) -> String {
        "workspaceTabs.tab.\(id.rawValue.uuidString.lowercased())"
    }

    static func closeTab(_ id: WorkspaceTabID) -> String {
        "workspaceTabs.close.\(id.rawValue.uuidString.lowercased())"
    }

    static func profile(_ id: WorkspaceProfileID) -> String {
        "workspaceProfiles.profile.\(id.rawValue.uuidString.lowercased())"
    }

    static func renameProfile(_ id: WorkspaceProfileID) -> String {
        "workspaceProfiles.rename.\(id.rawValue.uuidString.lowercased())"
    }

    static func openProfile(_ id: WorkspaceProfileID) -> String {
        "workspaceProfiles.open.\(id.rawValue.uuidString.lowercased())"
    }

    static func deleteProfile(_ id: WorkspaceProfileID) -> String {
        "workspaceProfiles.delete.\(id.rawValue.uuidString.lowercased())"
    }

    static let done = "workspaceProfiles.done"
}
