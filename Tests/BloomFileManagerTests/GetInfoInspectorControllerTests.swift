import AppKit
import Foundation
import Testing
@testable import BloomFileManager

@Suite("GetInfoInspectorControllerTests")
@MainActor
struct GetInfoInspectorControllerTests {
    @Test func panelIsReusableNonmodalAndUsesTheRequiredMinimumSize() {
        let model = GetInfoInspectorModel(inspector: NeverCompletingInspector(), checksumService: DeferredControllerChecksum())
        let controller = GetInfoInspectorController(model: model)
        let panel = controller.panel
        defer { controller.close() }

        controller.present(items: [controllerItem(named: "first.txt")])
        controller.close()
        controller.present(items: [controllerItem(named: "second.txt")])

        #expect(controller.panel === panel)
        #expect(panel.contentMinSize == NSSize(width: 420, height: 460))
        #expect(panel.styleMask.contains(.utilityWindow))
        #expect(!panel.worksWhenModal)
    }

    @Test func secondPresentCancelsAndReplacesModelInspection() async {
        let inspector = CancellationRecordingInspector()
        let model = GetInfoInspectorModel(inspector: inspector, checksumService: DeferredControllerChecksum())
        let controller = GetInfoInspectorController(model: model)
        defer { controller.close() }

        controller.present(items: [controllerItem(named: "first.txt")])
        #expect(await waitForControllerCondition { await inspector.requestCount == 1 })
        controller.present(items: [controllerItem(named: "second.txt")])

        #expect(await waitForControllerCondition { await inspector.cancelledCount == 1 })
        #expect(model.phase == .loading)
    }

    @Test func escapeCancelsAndClearsTheModel() async {
        let inspector = CancellationRecordingInspector()
        let model = GetInfoInspectorModel(inspector: inspector, checksumService: DeferredControllerChecksum())
        let controller = GetInfoInspectorController(model: model)
        defer { controller.close() }

        controller.present(items: [controllerItem(named: "escape.txt")])
        #expect(await waitForControllerCondition { await inspector.requestCount == 1 })
        controller.handleEscape()

        #expect(await waitForControllerCondition { await inspector.cancelledCount == 1 })
        #expect(model.phase == .idle)
        #expect(model.report == nil)
    }

    @Test func panelCloseCancelsAndClearsTheModel() async {
        let inspector = CancellationRecordingInspector()
        let model = GetInfoInspectorModel(inspector: inspector, checksumService: DeferredControllerChecksum())
        let controller = GetInfoInspectorController(model: model)
        let panel = controller.panel
        defer { controller.close() }

        controller.present(items: [controllerItem(named: "close.txt")])
        #expect(await waitForControllerCondition { await inspector.requestCount == 1 })
        panel.close()

        #expect(await waitForControllerCondition { await inspector.cancelledCount == 1 })
        #expect(model.phase == .idle)
        #expect(model.report == nil)
    }

    @Test func panelShellPublishesStableMeaningfulAccessibilitySemantics() {
        let model = GetInfoInspectorModel(
            inspector: NeverCompletingInspector(),
            checksumService: DeferredControllerChecksum()
        )
        let controller = GetInfoInspectorController(model: model)
        let panel = controller.panel
        defer { controller.close() }

        #expect(panel.accessibilityIdentifier() == "getInfo.panel")
        #expect(panel.accessibilityLabel() == "Get Info inspector")
        #expect(panel.accessibilityValue() as? String == "Read-only file metadata")
        #expect(panel.accessibilityHelp() == "Displays read-only metadata for the inspected selection.")
    }

    @Test func renderedInspectorHierarchyExposesEachStableIdentifierExactlyOnce() {
        let model = GetInfoInspectorModel(
            inspector: NeverCompletingInspector(),
            checksumService: DeferredControllerChecksum()
        )
        let controller = GetInfoInspectorController(model: model)
        let panel = controller.panel
        defer { controller.close() }

        panel.makeKeyAndOrderFront(nil)
        panel.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))

        let identifiers = accessibilityIdentifiers(in: panel)
        #expect(identifiers.filter { $0 == "getInfo.panel" }.count == 1)
        #expect(identifiers.filter { $0 == "getInfo.inspector.host" }.count == 1)
        #expect(identifiers.filter { $0 == "getInfo.inspector" }.count == 1)
        #expect(accessibilityValues(for: "getInfo.inspector", in: panel) == ["No selection inspected"])
    }
}

private actor NeverCompletingInspector: GetInfoInspecting {
    func inspect(_ items: [FileItem]) async throws -> GetInfoInspectionReport {
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}

private actor CancellationRecordingInspector: GetInfoInspecting {
    private(set) var requestCount = 0
    private(set) var cancelledCount = 0

    func inspect(_ items: [FileItem]) async throws -> GetInfoInspectionReport {
        requestCount += 1
        do {
            try await Task.sleep(for: .seconds(60))
            return .init(outcomes: [])
        } catch is CancellationError {
            cancelledCount += 1
            throw CancellationError()
        }
    }
}

private actor DeferredControllerChecksum: ChecksumService {
    func checksum(
        for request: ChecksumRequest,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> ChecksumResult {
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}

private func controllerItem(named name: String) -> FileItem {
    FileItem(
        url: URL(fileURLWithPath: "/tmp/GetInfoInspectorControllerTests/\(name)"),
        name: name,
        isDirectory: false,
        isPackage: false,
        modifiedAt: nil,
        byteSize: 1,
        typeDescription: "Plain text"
    )
}

private func waitForControllerCondition(
    timeout: Duration = .seconds(1),
    _ condition: @escaping @MainActor @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        guard clock.now < deadline else {
            Issue.record("Timed out waiting for controller condition.")
            return false
        }
        await Task.yield()
    }
    return true
}

private func accessibilityIdentifiers(in element: Any) -> [String] {
    guard let accessibilityElement = element as? NSObject else {
        return []
    }

    let identifier = accessibilityElement.responds(to: NSSelectorFromString("accessibilityIdentifier"))
        ? (accessibilityElement.value(forKey: "accessibilityIdentifier") as? String).map { [$0] } ?? []
        : []
    let children = accessibilityElement.responds(to: NSSelectorFromString("accessibilityChildren"))
        ? (accessibilityElement.value(forKey: "accessibilityChildren") as? [Any] ?? [])
        : []
    let childIdentifiers = children.flatMap(accessibilityIdentifiers)
    return identifier + childIdentifiers
}

private func accessibilityValues(for identifier: String, in element: Any) -> [String] {
    guard let accessibilityElement = element as? NSObject else {
        return []
    }

    let ownValue = accessibilityElement.responds(to: NSSelectorFromString("accessibilityIdentifier")) &&
        accessibilityElement.value(forKey: "accessibilityIdentifier") as? String == identifier
        ? (accessibilityElement.value(forKey: "accessibilityValue") as? String).map { [$0] } ?? []
        : []
    let children = accessibilityElement.responds(to: NSSelectorFromString("accessibilityChildren"))
        ? (accessibilityElement.value(forKey: "accessibilityChildren") as? [Any] ?? [])
        : []
    return ownValue + children.flatMap { accessibilityValues(for: identifier, in: $0) }
}
