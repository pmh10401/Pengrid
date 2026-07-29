// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "BloomFileManager",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "BloomFileManager", targets: ["BloomFileManager"])],
    targets: [
        .executableTarget(name: "BloomFileManager", path: "Sources/BloomFileManager"),
        .testTarget(name: "BloomFileManagerTests", dependencies: ["BloomFileManager"])
    ],
    swiftLanguageModes: [.v6]
)
