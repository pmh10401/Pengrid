// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "BloomFileManager",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "BloomFileManager", targets: ["BloomFileManager"])],
    targets: [
        .target(
            name: "EncryptedZIPCore",
            path: "Sources/EncryptedZIPCore",
            exclude: ["vendor/minizip-ng/LICENSE"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("config"),
                .headerSearchPath("vendor/minizip-ng"),
                .define("HAVE_PKCRYPT"),
                .define("HAVE_WZAES"),
                .define("HAVE_ZLIB"),
                .define("_DARWIN_C_SOURCE")
            ],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "BloomFileManager",
            dependencies: ["EncryptedZIPCore"],
            path: "Sources/BloomFileManager"
        ),
        .testTarget(
            name: "BloomFileManagerTests",
            dependencies: ["BloomFileManager", "EncryptedZIPCore"]
        )
    ],
    swiftLanguageModes: [.v6]
)
