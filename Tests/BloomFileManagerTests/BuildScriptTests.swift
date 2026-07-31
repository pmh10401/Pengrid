import Foundation
import Testing

@Test func buildScriptRejectsNonAppleSiliconHosts() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
        .appendingPathComponent("BloomFileManagerBuildScriptTests-\(UUID().uuidString)")
    try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    let fakeUname = temporaryDirectory.appendingPathComponent("uname")
    try "#!/usr/bin/env bash\necho x86_64\n".write(to: fakeUname, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeUname.path)

    let fakeSwift = temporaryDirectory.appendingPathComponent("swift")
    try "#!/usr/bin/env bash\necho 'unexpected build' >&2\nexit 17\n".write(to: fakeSwift, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSwift.path)

    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let script = repositoryRoot.appendingPathComponent("script/build_and_run.sh")

    let process = Process()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [script.path, "unsupported"]
    process.standardError = standardError
    process.environment = ProcessInfo.processInfo.environment.merging([
        "PATH": "\(temporaryDirectory.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")"
    ]) { _, replacement in replacement }

    try process.run()
    process.waitUntilExit()

    let errorOutput = String(data: standardError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    #expect(process.terminationStatus == 1)
    #expect(errorOutput.contains("requires an Apple Silicon (arm64) host"))
}

@Test func buildScriptUsesCanonicalPathChecksAndSafeLeafCleanup() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let script = repositoryRoot.appendingPathComponent("script/build_and_run.sh")
    let source = try String(contentsOf: script, encoding: .utf8)

    #expect(source.contains("assert_no_symlink_components"))
    #expect(source.contains("safe_delete_leaf"))
    #expect(source.contains("rm -rf") == false)
    #expect(source.contains("CFBundleShortVersionString"))
    #expect(source.contains("CFBundleVersion"))
    #expect(source.contains("APP_DISPLAY_NAME=\"Pengrid\""))
    #expect(source.contains("EXECUTABLE_NAME=\"BloomFileManager\""))
    #expect(source.contains("CFBundleExecutable</key><string>$EXECUTABLE_NAME"))
    #expect(source.contains("CFBundleDisplayName</key><string>$APP_DISPLAY_NAME"))
    #expect(source.contains("CFBundleIconFile</key><string>$ICON_NAME"))
    #expect(source.contains("Contents/Resources"))
    #expect(source.contains("ICON_SOURCE=\"$ROOT_DIR/Assets/Pengrid/$ICON_NAME\""))
    #expect(source.contains("exec 7<\"$APP_RESOURCES\""))
    #expect(source.contains("exec 8<\"$ICON_SOURCE\""))
    #expect(source.contains("/usr/bin/stat -f"))
    #expect(source.contains("openat(resourcesFD"))
    #expect(source.contains("read(sourceFD"))
    #expect(source.contains("write(stageFD"))
    #expect(source.contains("renameat(resourcesFD"))
    #expect(source.contains("fstatat(resourcesFD"))
    #expect(source.contains("/bin/mv") == false)
    #expect(source.contains("/usr/bin/mktemp") == false)
    #expect(source.contains("exec 9") == false)
    let openStage = try #require(source.range(of: "openat(resourcesFD"))
    let readSource = try #require(source.range(of: "read(sourceFD"))
    let writeStage = try #require(source.range(of: "write(stageFD"))
    let publish = try #require(source.range(of: "renameat(resourcesFD"))
    let closeSourceFD = try #require(source.range(of: "exec 8<&-"))
    #expect(openStage.lowerBound < readSource.lowerBound)
    #expect(readSource.lowerBound < writeStage.lowerBound)
    #expect(writeStage.lowerBound < publish.lowerBound)
    #expect(publish.lowerBound < closeSourceFD.lowerBound)
}

@Test func buildScriptCreatesPengridBundleWithCanonicalIconAndLegacyIdentity() throws {
    let fileManager = FileManager.default
    let temporaryPath = fileManager.temporaryDirectory.path
    let canonicalTemporaryPath = temporaryPath.hasPrefix("/var/")
        ? "/private\(temporaryPath)"
        : fileManager.temporaryDirectory.resolvingSymlinksInPath().path
    let temporaryRoot = URL(fileURLWithPath: canonicalTemporaryPath)
        .appendingPathComponent("PengridBuildFixture-\(UUID().uuidString)")
    let scriptDirectory = temporaryRoot.appendingPathComponent("script")
    let iconDirectory = temporaryRoot.appendingPathComponent("Assets/Pengrid")
    let fakeBin = temporaryRoot.appendingPathComponent("fake-bin")
    let fakeBuild = temporaryRoot.appendingPathComponent("fake-build")
    try fileManager.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: iconDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: fakeBuild, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: temporaryRoot) }

    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    try fileManager.copyItem(
        at: repositoryRoot.appendingPathComponent("script/build_and_run.sh"),
        to: scriptDirectory.appendingPathComponent("build_and_run.sh")
    )

    let canonicalIcon = Data("canonical-pengrid-icon".utf8)
    let canonicalIconURL = iconDirectory.appendingPathComponent("Pengrid.icns")
    try canonicalIcon.write(to: canonicalIconURL)

    let fakeExecutable = fakeBuild.appendingPathComponent("BloomFileManager")
    try "#!/usr/bin/env bash\nexit 0\n".write(
        to: fakeExecutable,
        atomically: true,
        encoding: .utf8
    )
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeExecutable.path)

    func writeFakeTool(named name: String, source: String) throws {
        let url = fakeBin.appendingPathComponent(name)
        try source.write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    try writeFakeTool(named: "uname", source: "#!/usr/bin/env bash\necho arm64\n")
    try writeFakeTool(named: "pkill", source: "#!/usr/bin/env bash\nexit 0\n")
    try writeFakeTool(named: "lldb", source: "#!/usr/bin/env bash\nexit 0\n")
    try writeFakeTool(
        named: "swift",
        source: """
        #!/usr/bin/env bash
        if [[ " $* " == *" --show-bin-path "* ]]; then
          echo "$FAKE_BUILD_DIR"
        fi
        exit 0
        """
    )

    let process = Process()
    let error = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [scriptDirectory.appendingPathComponent("build_and_run.sh").path, "debug"]
    process.standardError = error
    process.environment = ProcessInfo.processInfo.environment.merging([
        "FAKE_BUILD_DIR": fakeBuild.path,
        "PATH": "\(fakeBin.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")"
    ]) { _, replacement in replacement }
    try process.run()
    process.waitUntilExit()

    let errorOutput = String(
        data: error.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""
    #expect(process.terminationStatus == 0, Comment(rawValue: errorOutput))

    let bundle = temporaryRoot.appendingPathComponent("dist/Pengrid.app")
    let plistData = try Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
    let plist = try #require(
        PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
    )
    #expect(plist["CFBundleName"] as? String == "Pengrid")
    #expect(plist["CFBundleDisplayName"] as? String == "Pengrid")
    #expect(plist["CFBundleIconFile"] as? String == "Pengrid.icns")
    #expect(plist["CFBundleExecutable"] as? String == "BloomFileManager")
    #expect(plist["CFBundleIdentifier"] as? String == "com.minho.BloomFileManager")

    let bundledExecutable = bundle.appendingPathComponent("Contents/MacOS/BloomFileManager")
    #expect(fileManager.isExecutableFile(atPath: bundledExecutable.path))
    let bundledIcon = bundle.appendingPathComponent("Contents/Resources/Pengrid.icns")
    #expect(try Data(contentsOf: bundledIcon) == canonicalIcon)
}

@Test func developmentAndReleaseBundlesDeclareTheSameVersion() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let development = try String(
        contentsOf: repositoryRoot.appendingPathComponent("script/build_and_run.sh"),
        encoding: .utf8
    )
    let release = try String(
        contentsOf: repositoryRoot.appendingPathComponent("script/package_release.sh"),
        encoding: .utf8
    )

    for declaration in ["APP_VERSION=\"1.2.0\"", "BUILD_VERSION=\"3\""] {
        #expect(development.contains(declaration))
        #expect(release.contains(declaration))
    }
}

@Test func buildScriptRejectsInvocationThroughASymlinkedParentBeforeCleanup() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("BloomBuildSymlink.\(UUID().uuidString)")
    let external = root.appendingPathComponent("external")
    let scriptDirectory = external.appendingPathComponent("script")
    let link = root.appendingPathComponent("linked-repo")
    try fileManager.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }

    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    try fileManager.copyItem(
        at: repositoryRoot.appendingPathComponent("script/build_and_run.sh"),
        to: scriptDirectory.appendingPathComponent("build_and_run.sh")
    )
    let sentinel = external.appendingPathComponent("sentinel")
    try Data("keep".utf8).write(to: sentinel)
    try fileManager.createSymbolicLink(at: link, withDestinationURL: external)

    let process = Process()
    let error = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [link.appendingPathComponent("script/build_and_run.sh").path, "--verify"]
    process.standardError = error
    try process.run()
    process.waitUntilExit()

    let output = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    #expect(process.terminationStatus != 0)
    #expect(output.contains("symbolic link component"))
    #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
}
