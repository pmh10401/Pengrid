import Foundation
import Testing
@testable import BloomFileManager

@Suite struct SmartSearchTextAnalyzerTests {
    @Test func compatibilityAndChoseongQueriesCompileToTheSameInitials() {
        #expect(
            SmartSearchTextAnalyzer.queryPlan(for: "ㅎㄱ").clauses
                == SmartSearchTextAnalyzer.queryPlan(for: "ᄒᄀ").clauses
        )
    }

    @Test func queryCompilationCanBeCancelled() {
        let probe = AnalyzerCancellationProbe(allowedSteps: 32)

        #expect(throws: AnalyzerProbeError.cancelled) {
            try SmartSearchTextAnalyzer.queryPlan(
                for: String(repeating: "ㅎㄱ report ", count: 1_000),
                analysisStep: probe.step
            )
        }
    }

    @Test func mixedAndAdjacentScriptsCompileIntoOrderedAndClauses() {
        #expect(SmartSearchTextAnalyzer.queryPlan(for: "ㅎㄱ report").clauses == [
            .hangulInitials([.hieuh, .kiyeok]),
            .literal("report")
        ])
        #expect(SmartSearchTextAnalyzer.queryPlan(for: "2026ㅎㄱ").clauses == [
            .literal("2026"),
            .hangulInitials([.hieuh, .kiyeok])
        ])
        #expect(SmartSearchTextAnalyzer.queryPlan(for: "ㅎ ㄱ").clauses == [
            .hangulInitials([.hieuh]),
            .hangulInitials([.kiyeok])
        ])
    }

    @Test func unsupportedCompoundFinalRemainsLiteral() {
        #expect(SmartSearchTextAnalyzer.queryPlan(for: "ㄳ").clauses == [.literal("ㄳ")])
    }

    @Test func oldHangulAndJongseongJamoRemainLiteral() {
        let oldChoseong = "\u{1113}"
        let jongseong = "\u{11A8}"

        #expect(SmartSearchTextAnalyzer.queryPlan(for: oldChoseong).clauses == [
            .literal(oldChoseong)
        ])
        #expect(SmartSearchTextAnalyzer.queryPlan(for: jongseong).clauses == [
            .literal(jongseong)
        ])
        #expect(SmartSearchTextAnalyzer.match(
            plan: SmartSearchTextAnalyzer.queryPlan(for: oldChoseong),
            filename: "가.txt",
            relativePath: "가.txt"
        ) == nil)
    }

    @Test func syllableRunsMatchKoreanWordsAcrossCanonicalForms() {
        let plan = SmartSearchTextAnalyzer.queryPlan(for: "ㅎㄱ")

        #expect(SmartSearchTextAnalyzer.match(
            plan: plan,
            filename: "한국.txt",
            relativePath: "한국.txt"
        ) != nil)
        #expect(SmartSearchTextAnalyzer.match(
            plan: plan,
            filename: "한글.txt",
            relativePath: "한글.txt"
        ) != nil)
        #expect(SmartSearchTextAnalyzer.match(
            plan: plan,
            filename: "한글".decomposedStringWithCanonicalMapping,
            relativePath: "한글".decomposedStringWithCanonicalMapping
        ) != nil)
    }

    @Test func everyModernInitialMatchesItsRepresentativeSyllable() {
        let pairs = [
            ("ㄱ", "가"), ("ㄲ", "까"), ("ㄴ", "나"), ("ㄷ", "다"), ("ㄸ", "따"),
            ("ㄹ", "라"), ("ㅁ", "마"), ("ㅂ", "바"), ("ㅃ", "빠"), ("ㅅ", "사"),
            ("ㅆ", "싸"), ("ㅇ", "아"), ("ㅈ", "자"), ("ㅉ", "짜"), ("ㅊ", "차"),
            ("ㅋ", "카"), ("ㅌ", "타"), ("ㅍ", "파"), ("ㅎ", "하")
        ]

        for (query, filename) in pairs {
            #expect(SmartSearchTextAnalyzer.match(
                plan: SmartSearchTextAnalyzer.queryPlan(for: query),
                filename: filename,
                relativePath: filename
            ) != nil)
        }
    }

    @Test func runHeadsMatchWordsButDoNotAllowArbitrarySubsequences() {
        let plan = SmartSearchTextAnalyzer.queryPlan(for: "ㄱㄷ")

        #expect(SmartSearchTextAnalyzer.match(
            plan: plan,
            filename: "구글 드라이브",
            relativePath: "구글 드라이브"
        ) != nil)
        #expect(SmartSearchTextAnalyzer.match(
            plan: plan,
            filename: "개인 사진 다운로드",
            relativePath: "개인 사진 다운로드"
        ) == nil)
    }

    @Test func nonHangulSegmentsBreakRunHeadGroups() {
        let plan = SmartSearchTextAnalyzer.queryPlan(for: "ㄱㄷ")

        #expect(SmartSearchTextAnalyzer.match(
            plan: plan,
            filename: "계획.txt",
            relativePath: "구글/드라이브/계획.txt"
        ) != nil)
        #expect(SmartSearchTextAnalyzer.match(
            plan: plan,
            filename: "계획.txt",
            relativePath: "구글/2026/드라이브/계획.txt"
        ) == nil)
        #expect(SmartSearchTextAnalyzer.match(
            plan: plan,
            filename: "구글Drive드라이브",
            relativePath: "구글Drive드라이브"
        ) == nil)
    }

    @Test func punctuationJoinsAdjacentKoreanHeadsButDigitsBreakThem() {
        let plan = SmartSearchTextAnalyzer.queryPlan(for: "ㄱㄷ")

        #expect(SmartSearchTextAnalyzer.match(
            plan: plan,
            filename: "구글-드라이브",
            relativePath: "구글-드라이브"
        ) != nil)
        #expect(SmartSearchTextAnalyzer.match(
            plan: plan,
            filename: "구글.드라이브",
            relativePath: "구글.드라이브"
        ) != nil)
        #expect(SmartSearchTextAnalyzer.match(
            plan: plan,
            filename: "구글2026드라이브",
            relativePath: "구글2026드라이브"
        ) == nil)
    }

    @Test func mixedClausesRequireEveryLiteralAndInitialCondition() {
        let plan = SmartSearchTextAnalyzer.queryPlan(for: "ㅎㄱ report")

        #expect(SmartSearchTextAnalyzer.match(
            plan: plan,
            filename: "한국 report.pdf",
            relativePath: "한국 report.pdf"
        ) != nil)
        #expect(SmartSearchTextAnalyzer.match(
            plan: plan,
            filename: "한국 notes.pdf",
            relativePath: "한국 notes.pdf"
        ) == nil)
        #expect(SmartSearchTextAnalyzer.match(
            plan: plan,
            filename: "영문 report.pdf",
            relativePath: "영문 report.pdf"
        ) == nil)
    }

    @Test func doubleInitialDoesNotEqualTwoSingleInitials() {
        #expect(SmartSearchTextAnalyzer.match(
            plan: SmartSearchTextAnalyzer.queryPlan(for: "ㄲ"),
            filename: "까치",
            relativePath: "까치"
        ) != nil)
        #expect(SmartSearchTextAnalyzer.match(
            plan: SmartSearchTextAnalyzer.queryPlan(for: "ㄱㄱ"),
            filename: "까치",
            relativePath: "까치"
        ) == nil)
    }

    @Test func literalMatchingKeepsCaseAndDiacriticInsensitiveBehavior() {
        let plan = SmartSearchTextAnalyzer.queryPlan(for: "CAFÉ 보고서")

        #expect(SmartSearchTextAnalyzer.match(
            plan: plan,
            filename: "Cafe 보고서.txt",
            relativePath: "Archive/Cafe 보고서.txt"
        ) != nil)
    }

    @Test func explicitInitialFilenameUsesLiteralEvidenceBeforeDerivedPathEvidence() {
        let match = SmartSearchTextAnalyzer.match(
            plan: SmartSearchTextAnalyzer.queryPlan(for: "ㅎㄱ"),
            filename: "ㅎㄱ.txt",
            relativePath: "한국/ㅎㄱ.txt"
        )

        #expect(match?.initialEvidence.first?.key == SmartSearchInitialEvidenceKey(
            field: .filename,
            representation: .literal,
            relation: .exact
        ))
    }

    @Test func initialOccurrencesCountOverlappingMatches() {
        let match = SmartSearchTextAnalyzer.match(
            plan: SmartSearchTextAnalyzer.queryPlan(for: "ㄱㄱ"),
            filename: "가가가",
            relativePath: "가가가"
        )

        #expect(match?.initialEvidence.first?.weightedTermFrequency == 2)
    }

    @Test func cancellationCanInterruptAdversarialInitialScanning() {
        let candidate = String(repeating: "가", count: 256)
        let plan = SmartSearchTextAnalyzer.queryPlan(
            for: String(repeating: "ㄱ", count: 64) + "ㄴ"
        )
        let probe = AnalyzerCancellationProbe(
            allowedSteps: (candidate.unicodeScalars.count * 2) + 8
        )

        #expect(throws: AnalyzerProbeError.cancelled) {
            try SmartSearchTextAnalyzer.match(
                plan: plan,
                filename: candidate,
                relativePath: candidate,
                analysisStep: probe.step
            )
        }
    }

    @Test func initialAnalysisAndMatchingWorkScaleLinearly() throws {
        let singleText = String(repeating: "가", count: 64)
        let singlePlan = SmartSearchTextAnalyzer.queryPlan(
            for: String(repeating: "ㄱ", count: 16) + "ㄴ"
        )
        let singleCounter = AnalyzerStepCounter()
        _ = try SmartSearchTextAnalyzer.match(
            plan: singlePlan,
            filename: singleText,
            relativePath: singleText,
            analysisStep: singleCounter.increment
        )

        let doubledText = String(repeating: "가", count: 128)
        let doubledPlan = SmartSearchTextAnalyzer.queryPlan(
            for: String(repeating: "ㄱ", count: 32) + "ㄴ"
        )
        let doubledCounter = AnalyzerStepCounter()
        _ = try SmartSearchTextAnalyzer.match(
            plan: doubledPlan,
            filename: doubledText,
            relativePath: doubledText,
            analysisStep: doubledCounter.increment
        )

        #expect(singleCounter.value > singleText.unicodeScalars.count * 2)
        #expect(doubledCounter.value <= (singleCounter.value * 2) + 16)
    }
}

private enum AnalyzerProbeError: Error {
    case cancelled
}

private final class AnalyzerCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let allowedSteps: Int
    private var count = 0

    init(allowedSteps: Int) {
        self.allowedSteps = allowedSteps
    }

    func step() throws {
        let shouldCancel = lock.withLock {
            count += 1
            return count > allowedSteps
        }
        if shouldCancel {
            throw AnalyzerProbeError.cancelled
        }
    }
}

private final class AnalyzerStepCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
