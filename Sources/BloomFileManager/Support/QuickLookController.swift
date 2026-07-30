import QuickLookUI

@MainActor
final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var urls: [URL] = []
    private let onPresent: (@MainActor ([URL]) -> Void)?
    private var requestGeneration: UInt = 0
    private(set) var isPresenting = false

    init(onPresent: (@MainActor ([URL]) -> Void)? = nil) {
        self.onPresent = onPresent
    }

    func invalidatePendingPreparationForSelectionChange() {
        guard !Task.isCancelled else { return }
        requestGeneration &+= 1
    }

    func prepareAndPresent(
        requests: [IdentifiedFileRequest],
        materializer: any CloudMaterializing
    ) async {
        requestGeneration &+= 1
        let generation = requestGeneration
        guard !requests.isEmpty else {
            presentPrepared(urls: [])
            return
        }
        let result = await materializer.materialize(
            requests,
            purpose: .quickLook,
            progress: { _ in }
        )
        guard generation == requestGeneration,
              !Task.isCancelled,
              !result.wasCancelled,
              result.failures.isEmpty,
              let prepared = CloudOperationRequestGate.identityPreservingPreparedRequests(
                  original: requests,
                  prepared: result.preparedRequests
              )
        else { return }
        presentPrepared(urls: prepared.map(\.url))
    }

    func updateIfPresented(
        requests: [IdentifiedFileRequest],
        materializer: any CloudMaterializing
    ) async {
        guard !Task.isCancelled else { return }
        requestGeneration &+= 1
        let generation = requestGeneration
        guard isPresenting else { return }
        guard !requests.isEmpty else {
            presentPrepared(urls: [])
            return
        }
        let result = await materializer.materialize(
            requests,
            purpose: .quickLook,
            progress: { _ in }
        )
        guard generation == requestGeneration, !Task.isCancelled else { return }
        guard !result.wasCancelled,
              result.failures.isEmpty,
              let prepared = CloudOperationRequestGate.identityPreservingPreparedRequests(
                  original: requests,
                  prepared: result.preparedRequests
              )
        else {
            presentPrepared(urls: [])
            return
        }
        presentPrepared(urls: prepared.map(\.url))
    }

    private func presentPrepared(urls: [URL]) {
        isPresenting = !urls.isEmpty
        self.urls = urls
        if let onPresent {
            onPresent(urls)
            return
        }

        guard !urls.isEmpty else {
            guard QLPreviewPanel.sharedPreviewPanelExists() else { return }
            QLPreviewPanel.shared().close()
            return
        }

        let panel = QLPreviewPanel.shared()
        panel?.dataSource = self
        panel?.delegate = self
        panel?.reloadData()
        panel?.currentPreviewItemIndex = 0
        panel?.makeKeyAndOrderFront(nil)
    }

    func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        requestGeneration &+= 1
        urls.removeAll()
        isPresenting = false
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem {
        urls[index] as NSURL
    }
}
