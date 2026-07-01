import Foundation

@MainActor
class DownloadManager: ObservableObject {
    @Published var downloads: [DownloadItem] = []

    private var transferManager: TransferManager?

    /// Wires this manager up to a live client. Must be called before enqueue(_:)
    /// will actually attempt anything beyond adding a queued row to the list.
    func attach(to client: SoulseekClient, settings: AppSettings) {
        let manager = TransferManager(client: client, peerManager: client.peerManager, settings: settings)
        manager.onStateChange = { [weak self] id, state in
            guard let self else { return }
            guard let index = self.downloads.firstIndex(where: { $0.id == id }) else { return }
            self.downloads[index].state = state
        }
        transferManager = manager
    }

    func enqueue(_ result: SearchResult) {
        let item = DownloadItem(
            username: result.username,
            filename: result.filename,
            remotePath: result.remotePath
        )
        downloads.append(item)

        guard let transferManager else {
            // Not attached to a client yet — leave it queued rather than crash;
            // this shouldn't happen in practice since ContentView attaches on appear.
            return
        }
        transferManager.startDownload(id: item.id, username: result.username, remotePath: result.remotePath)
    }

    /// Enqueues every file in a folder at once — the mobile equivalent of the
    /// desktop client's "Download Folder" action. Each file becomes its own
    /// DownloadItem row; TransferManager bounds how many run concurrently per
    /// peer internally, so the rest just sit in the existing "Queued" state
    /// until their turn.
    func enqueueFolder(_ results: [SearchResult]) {
        for result in results {
            enqueue(result)
        }
    }
}