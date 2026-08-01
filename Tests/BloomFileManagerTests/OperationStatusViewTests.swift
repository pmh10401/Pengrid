import Testing
@testable import BloomFileManager

@Test func compressionStatusHasAnArchiveStageAndStableVoiceOverLabels() {
    let progress = ArchiveOperationProgress(
        kind: .compress,
        currentDisplayName: "Reports.zip"
    )
    #expect(FileOperationStage.archiving(progress) == .archiving(progress))

    let presentation = ArchiveOperationStatusPresentation(progress: progress)
    #expect(presentation.title == "Compressing ZIP archive")
    #expect(presentation.currentItemName == "Reports.zip")
    #expect(
        presentation.statusAccessibilityLabel
            == "Compressing ZIP archive, current item Reports.zip"
    )
    #expect(presentation.cancelAccessibilityLabel == "Cancel ZIP compression")
}

@Test func extractionStatusHasOperationSpecificStableVoiceOverLabels() {
    let presentation = ArchiveOperationStatusPresentation(progress: ArchiveOperationProgress(
        kind: .extract,
        currentDisplayName: "Backup.zip"
    ))

    #expect(presentation.title == "Extracting ZIP archive")
    #expect(presentation.currentItemName == "Backup.zip")
    #expect(
        presentation.statusAccessibilityLabel
            == "Extracting ZIP archive, current item Backup.zip"
    )
    #expect(presentation.cancelAccessibilityLabel == "Cancel ZIP extraction")
}

@Test func tarGzipCompressionStatusNamesItsFormatForVisualAndVoiceOverUsers() {
    let presentation = ArchiveOperationStatusPresentation(progress: ArchiveOperationProgress(
        kind: .compress,
        currentDisplayName: "Reports.tar.gz",
        format: .tarGzip
    ))

    #expect(presentation.title == "Compressing TAR.GZ archive")
    #expect(
        presentation.statusAccessibilityLabel
            == "Compressing TAR.GZ archive, current item Reports.tar.gz"
    )
    #expect(presentation.cancelAccessibilityLabel == "Cancel TAR.GZ compression")
}
