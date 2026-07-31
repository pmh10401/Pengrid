import Testing
@testable import BloomFileManager

@Test func compressionStatusHasAnArchiveStageAndStableVoiceOverLabels() {
    let progress = ArchiveOperationProgress(
        kind: .compress,
        currentDisplayName: "Reports.zip"
    )
    #expect(FileOperationStage.archiving(progress) == .archiving(progress))

    let presentation = ArchiveOperationStatusPresentation(progress: progress)
    #expect(presentation.title == "Compressing")
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

    #expect(presentation.title == "Extracting")
    #expect(presentation.currentItemName == "Backup.zip")
    #expect(
        presentation.statusAccessibilityLabel
            == "Extracting ZIP archive, current item Backup.zip"
    )
    #expect(presentation.cancelAccessibilityLabel == "Cancel ZIP extraction")
}
