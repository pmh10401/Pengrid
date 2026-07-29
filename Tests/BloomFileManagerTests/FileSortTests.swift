import Testing
@testable import BloomFileManager

@Test func fileSortUsesDefaultAndReplacementValues() {
    let defaultSort = FileSort()
    let replacementSort = FileSort(key: .size, direction: .descending)

    #expect(defaultSort.key == .name)
    #expect(defaultSort.direction == .ascending)
    #expect(replacementSort.key == .size)
    #expect(replacementSort.direction == .descending)
}
