import Foundation

@MainActor
class DownloadManager: ObservableObject {
    @Published var downloads: [DownloadItem] = []

    // TODO (Phase 6): implement peer connection and file transfer
    func enqueue(_ result: SearchResult) {
        let item = DownloadItem(
            username: result.username,
            filename: result.filename,
            remotePath: result.remotePath
        )
        downloads.append(item)
    }
}
