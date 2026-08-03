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
            == "Compressing ZIP archive, Encoding archive, current item Reports.zip"
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
            == "Extracting ZIP archive, Encoding archive, current item Backup.zip"
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
            == "Compressing TAR.GZ archive, Encoding archive, current item Reports.tar.gz"
    )
    #expect(presentation.cancelAccessibilityLabel == "Cancel TAR.GZ compression")
}

@Test func archivePreparationClampsAndReportsDeterminateFraction() {
    let progress = ArchiveOperationProgress(
        kind: .compress,
        currentDisplayName: "Reports.zip",
        format: .zip,
        phase: .preparingSources(completedCount: 2, totalCount: 4)
    )

    #expect(progress.fractionCompleted == 0.5)
    #expect(
        ArchiveOperationStatusPresentation(progress: progress).progressLabel
            == "Preparing files, 2 of 4"
    )
}

@Test func archivePreparationSanitizesInvalidCounts() {
    let negative = ArchiveOperationProgress(
        kind: .compress,
        currentDisplayName: "Reports.zip",
        phase: .preparingSources(completedCount: -3, totalCount: 4)
    )
    let overflow = ArchiveOperationProgress(
        kind: .compress,
        currentDisplayName: "Reports.zip",
        phase: .preparingSources(completedCount: 9, totalCount: 4)
    )
    let empty = ArchiveOperationProgress(
        kind: .compress,
        currentDisplayName: "Reports.zip",
        phase: .preparingSources(completedCount: 0, totalCount: 0)
    )

    #expect(negative.fractionCompleted == 0)
    #expect(overflow.fractionCompleted == 1)
    #expect(empty.fractionCompleted == 0)
    #expect(ArchiveOperationStatusPresentation(progress: negative).progressLabel
        == "Preparing files, 0 of 4")
    #expect(ArchiveOperationStatusPresentation(progress: overflow).progressLabel
        == "Preparing files, 4 of 4")
    #expect(ArchiveOperationStatusPresentation(progress: empty).progressLabel
        == "Preparing files, 0 of 0")
}

@Test func encodingAndPublishingRemainIndeterminate() {
    let encoding = ArchiveOperationProgress(
        kind: .compress,
        currentDisplayName: "Reports.tar.gz",
        format: .tarGzip,
        phase: .encoding
    )
    let publishing = ArchiveOperationProgress(
        kind: .compress,
        currentDisplayName: "Reports.tar.gz",
        format: .tarGzip,
        phase: .publishing
    )

    #expect(encoding.fractionCompleted == nil)
    #expect(publishing.fractionCompleted == nil)
    #expect(ArchiveOperationStatusPresentation(progress: encoding).progressLabel
        == "Encoding archive")
    #expect(ArchiveOperationStatusPresentation(progress: publishing).progressLabel
        == "Finishing archive")
}
