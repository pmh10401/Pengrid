import Foundation

private final class IsolatedTestBundleMarker: NSObject {}

func isolatedTestBundleExecutableURL() throws -> URL {
    let bundle = Bundle(for: IsolatedTestBundleMarker.self)
    guard bundle.bundleURL.pathExtension == "xctest",
          let executableURL = bundle.executableURL,
          executableURL.isFileURL,
          FileManager.default.isExecutableFile(atPath: executableURL.path)
    else {
        throw CocoaError(
            .executableNotLoadable,
            userInfo: [
                NSLocalizedDescriptionKey: "Unable to resolve the loaded test bundle executable at \(bundle.bundleURL.path)"
            ]
        )
    }
    return executableURL
}
