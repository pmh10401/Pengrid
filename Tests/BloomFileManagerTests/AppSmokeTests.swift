import Testing
@testable import BloomFileManager

@Test func productIdentityUsesPengridWithoutBreakingLegacyInternals() {
    #expect(AppIdentity.displayName == "Pengrid")
    #expect(AppIdentity.executableName == "BloomFileManager")
    #expect(AppIdentity.bundleIdentifier == "com.minho.BloomFileManager")
}
