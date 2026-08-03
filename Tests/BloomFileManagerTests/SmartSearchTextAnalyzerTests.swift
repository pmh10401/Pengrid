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

    @Test func mixedAndAdjacentScriptsCompileIntoOrderedAndClauses() {
        #expect(SmartSearchTextAnalyzer.queryPlan(for: "ㅎㄱ report").clauses == [
            .hangulInitials([.hieuh, .kiyeok]),
            .literal("report")
        ])
        #expect(SmartSearchTextAnalyzer.queryPlan(for: "2026ㅎㄱ").clauses == [
            .literal("2026"),
            .hangulInitials([.hieuh, .kiyeok])
        ])
    }

    @Test func unsupportedCompoundFinalRemainsLiteral() {
        #expect(SmartSearchTextAnalyzer.queryPlan(for: "ㄳ").clauses == [.literal("ㄳ")])
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
}
