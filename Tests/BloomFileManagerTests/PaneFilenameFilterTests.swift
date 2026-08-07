import Foundation
import Testing
@testable import BloomFileManager

struct PaneFilenameFilterTests {
    @Test func emptyQueryKeepsEveryItemInInputOrder() {
        let items = filterItems("Zulu.txt", "alpha.txt", "한글.pdf")
        #expect(PaneFilenameFilter(query: "").apply(to: items) == items)
        #expect(PaneFilenameFilter(query: "   ").apply(to: items) == items)
    }

    @Test func matchingIsLocalizedCaseAndDiacriticInsensitive() {
        let items = filterItems("Résumé.PDF", "resume-notes.txt", "photo.jpg")
        let matches = PaneFilenameFilter(query: "RESUME").apply(to: items)
        #expect(matches.map(\.name) == ["Résumé.PDF", "resume-notes.txt"])
    }

    @Test func koreanSubstringMatchingKeepsOriginalOrder() {
        let items = filterItems("여행사진.heic", "업무보고서.pdf", "여행계획.md")
        let matches = PaneFilenameFilter(query: "여행").apply(to: items)
        #expect(matches.map(\.name) == ["여행사진.heic", "여행계획.md"])
    }

    @Test func localizedMatchingCounterexamplesPreventGlobalCandidateNarrowing() {
        #expect(!"ß".localizedStandardContains("s"))
        #expect("ß".localizedStandardContains("ss"))
        #expect(!"⑫".localizedStandardContains("1"))
        #expect("⑫".localizedStandardContains("12"))
    }

    @Test func printableASCIIPartitionUsesTheExactApprovedScalarRange() {
        #expect(PaneFilenameFilter.isPrintableASCII("report-1999.txt"))
        #expect(PaneFilenameFilter.isPrintableASCII(" !~"))
        #expect(!PaneFilenameFilter.isPrintableASCII(""))
        #expect(!PaneFilenameFilter.isPrintableASCII("보고서.txt"))
        #expect(!PaneFilenameFilter.isPrintableASCII("Résumé.pdf"))
    }

    @Test func eligibleASCIIExtensionRequiresOneNormalizedASCIIAlphanumericSuffix() {
        #expect(PaneFilenameFilter.isEligibleASCIIExtension(from: " report ", to: "report2"))
        #expect(!PaneFilenameFilter.isEligibleASCIIExtension(from: "report", to: "report-"))
        #expect(!PaneFilenameFilter.isEligibleASCIIExtension(from: "report", to: "reports2"))
        #expect(!PaneFilenameFilter.isEligibleASCIIExtension(from: "보고", to: "보고서"))
        #expect(!PaneFilenameFilter.isEligibleASCIIExtension(from: "", to: "a"))
    }
}

private func filterItems(_ names: String...) -> [FileItem] {
    names.map { name in
        FileItem(
            url: URL(filePath: "/filter/\(name)"),
            name: name,
            isDirectory: false,
            isPackage: false,
            modifiedAt: nil,
            byteSize: 1,
            typeDescription: "File"
        )
    }
}
