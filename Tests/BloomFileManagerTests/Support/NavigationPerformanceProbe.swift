import AppKit
import Foundation
import SwiftUI
@testable import BloomFileManager

struct ListingPerformanceSample: Sendable {
    let firstBatch: Duration
    let complete: Duration
    let batchCount: Int
    let itemCount: Int
}

func measureListing(
    service: any DirectoryListingService,
    directory: URL,
    clock: ContinuousClock = .init()
) async throws -> ListingPerformanceSample {
    let start = clock.now
    var first: Duration?
    var batches = 0
    var items = 0
    for try await batch in service.batches(in: directory) {
        if first == nil { first = start.duration(to: clock.now) }
        batches += 1
        items += batch.count
    }
    let complete = start.duration(to: clock.now)
    return .init(
        firstBatch: first ?? complete,
        complete: complete,
        batchCount: batches,
        itemCount: items
    )
}

struct TablePopulationPerformanceSample: Sendable {
    let requestToFirstNonemptyRows: Duration
    let coordinatorApplication: Duration
    let rowCount: Int
}

@MainActor
func measureFirstRenderedTableState(
    firstNonemptyItems items: [FileItem],
    clock: ContinuousClock = .init()
) -> TablePopulationPerformanceSample {
    precondition(!items.isEmpty, "The first rendered table state must be nonempty")

    let view = FileTableView(
        items: [],
        selection: .constant([]),
        onActivatePane: {},
        onOpen: { _ in },
        onSortChange: { _ in }
    )
    let coordinator = view.makeCoordinator()
    let scrollView = view.makeScrollView(coordinator: coordinator)
    scrollView.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
    let tableView = scrollView.documentView as! NSTableView
    tableView.frame = NSRect(x: 0, y: 0, width: 700, height: 300)

    let requestStart = clock.now
    let applicationStart = clock.now
    coordinator.apply(items: items, selection: [], to: tableView)
    let coordinatorApplication = applicationStart.duration(to: clock.now)
    tableView.layoutSubtreeIfNeeded()
    let requestToFirstNonemptyRows = requestStart.duration(to: clock.now)

    return .init(
        requestToFirstNonemptyRows: requestToFirstNonemptyRows,
        coordinatorApplication: coordinatorApplication,
        rowCount: tableView.numberOfRows
    )
}
