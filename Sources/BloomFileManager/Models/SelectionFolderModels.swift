import Foundation

struct SelectionFolderPlan: Sendable, Equatable {
    let parentURL: URL
    let parentIdentity: FileIdentity
    let folderName: String
    let folderURL: URL
    let sources: [ContextActionSource]
}
