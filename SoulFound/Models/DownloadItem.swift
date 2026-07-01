import Foundation

enum DownloadState {
    case queued
    case downloading(progress: Double, speedBytesPerSec: Double)
    case completed
    case failed(reason: String)
}

struct DownloadItem: Identifiable {
    let id = UUID()
    let username: String
    let filename: String
    let remotePath: String
    var state: DownloadState = .queued
}