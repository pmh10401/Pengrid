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

@Test func protectedCompressionByteProgressUsesEncryptingLabelAndByteCountFormatter() {
    let progress = ArchiveOperationProgress(
        kind: .compress,
        currentDisplayName: "자료.zip",
        format: .zip,
        phase: .processingBytes(completedByteCount: 25, totalByteCount: 100)
    )
    let presentation = ArchiveOperationStatusPresentation(progress: progress)

    #expect(presentation.progressLabel == "Encrypting archive, 25 of 100 bytes")
    #expect(presentation.statusAccessibilityLabel.contains("자료.zip"))
    #expect(presentation.statusAccessibilityLabel.contains("password") == false)
    #expect(presentation.statusAccessibilityLabel.contains("secret-sentinel-passphrase") == false)
}

@Test func extractionByteProgressUsesExtractingLabelAndBoundedCounts() {
    let progress = ArchiveOperationProgress(
        kind: .extract,
        currentDisplayName: "Backup.zip",
        format: .zip,
        phase: .processingBytes(completedByteCount: 9_999, totalByteCount: 100)
    )
    let presentation = ArchiveOperationStatusPresentation(progress: progress)

    #expect(presentation.progressLabel == "Extracting archive, 100 of 100 bytes")
    #expect(presentation.statusAccessibilityLabel ==
        "Extracting ZIP archive, Extracting archive, 100 of 100 bytes, current item Backup.zip")
}

@Test func waitingForPasswordIsIndeterminateAndSecretFree() {
    let presentation = ArchiveOperationStatusPresentation(progress: ArchiveOperationProgress(
        kind: .compress,
        currentDisplayName: "Protected.zip",
        format: .zip,
        phase: .waitingForPassword
    ))

    #expect(presentation.progressLabel == "Waiting for password")
    #expect(presentation.statusAccessibilityLabel ==
        "Compressing ZIP archive, Waiting for password, current item Protected.zip")
    #expect(presentation.statusAccessibilityLabel.contains("secret-sentinel-passphrase") == false)
}

@Test func unknownOrNonPositiveByteTotalsStayIndeterminate() {
    for total in [Int64?.none, 0, -1] {
        let progress = ArchiveOperationProgress(
            kind: .compress,
            currentDisplayName: "Protected.zip",
            phase: .processingBytes(completedByteCount: 50, totalByteCount: total)
        )
        let presentation = ArchiveOperationStatusPresentation(progress: progress)
        #expect(progress.fractionCompleted == nil)
        #expect(presentation.progressLabel == "Encrypting archive")
    }
}

@Test func batchRenamePhasesHaveBoundedSecretFreeAccessibilityLabels() {
    let expectations: [(BatchRenameTransactionPhase, String)] = [
        (.staging, "Preparing Names"),
        (.publishing, "Renaming Items"),
        (.rollingBack, "Restoring Names")
    ]

    for (phase, title) in expectations {
        let presentation = BatchRenameOperationStatusPresentation(
            progress: BatchRenameTransactionProgress(
                phase: phase,
                completedCount: 9,
                totalCount: 2,
                currentName: "/private/Secret\nName.txt"
            )
        )
        #expect(presentation.title == title)
        #expect(presentation.completedCount == 2)
        #expect(presentation.totalCount == 2)
        #expect(presentation.currentItemName == "Secret Name.txt")
        #expect(presentation.accessibilityLabel ==
            "\(title), 2 of 2, current item Secret Name.txt")
        #expect(!presentation.accessibilityLabel.contains("/private"))
    }
}

@Test func folderSynchronizationPhasesHaveBoundedRelativePathOnlyAccessibilityLabels() throws {
    let expectations: [(FolderSynchronizationTransactionPhase, String)] = [
        (.preflighting, "Checking Folders"),
        (.staging, "Staging Copies"),
        (.verifyingStaging, "Verifying Staged Copies"),
        (.quarantining, "Quarantining Destinations"),
        (.publishing, "Publishing Copies"),
        (.verifyingPublished, "Verifying Published Copies"),
        (.movingToTrash, "Moving to Trash"),
        (.rollingBack, "Restoring Folders")
    ]
    let relativePath = try ComparisonRelativePath(components: ["docs", "Secret\nName.txt"])

    for (phase, title) in expectations {
        let presentation = FolderSynchronizationOperationStatusPresentation(
            progress: FolderSynchronizationProgress(
                phase: phase,
                completedCount: 9,
                totalCount: 2,
                currentRelativePath: relativePath
            )
        )
        #expect(presentation.title == title)
        #expect(presentation.completedCount == 2)
        #expect(presentation.totalCount == 2)
        #expect(presentation.currentItemName == "docs/Secret Name.txt")
        #expect(presentation.accessibilityLabel ==
            "\(title), 2 of 2, current item docs/Secret Name.txt")
        #expect(!presentation.accessibilityLabel.contains("/private"))
        #expect(!presentation.accessibilityLabel.contains("/SecretSource"))
        #expect(!presentation.progressDetail.contains("/private"))
        #expect(FileOperationStage.synchronizing(FolderSynchronizationProgress(
            phase: phase,
            completedCount: 1,
            totalCount: 2,
            currentRelativePath: relativePath
        )) == .synchronizing(FolderSynchronizationProgress(
            phase: phase,
            completedCount: 1,
            totalCount: 2,
            currentRelativePath: relativePath
        )))
    }
}

@Test func selectionEnclosurePhasesHaveBoundedBasenameOnlyAccessibilityLabels() {
    let expectations: [(SelectionFolderTransactionPhase, String)] = [
        (.creatingFolder, "Creating Folder"),
        (.movingItems, "Moving Selected Items"),
        (.rollingBack, "Restoring Selected Items")
    ]

    for (phase, title) in expectations {
        let presentation = SelectionFolderOperationStatusPresentation(
            progress: SelectionFolderTransactionProgress(
                phase: phase,
                completedCount: 9,
                totalCount: 2,
                currentName: "/private/Secret\nName.txt"
            )
        )
        #expect(presentation.title == title)
        #expect(presentation.completedCount == 2)
        #expect(presentation.totalCount == 2)
        #expect(presentation.currentItemName == "Secret Name.txt")
        #expect(presentation.accessibilityLabel ==
            "\(title), 2 of 2, current item Secret Name.txt")
        #expect(!presentation.accessibilityLabel.contains("/private"))
    }
}
