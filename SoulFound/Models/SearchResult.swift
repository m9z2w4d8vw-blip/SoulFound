import Foundation

struct SearchResult: Identifiable {
    let id = UUID()
    let username: String
    let filename: String
    let size: Int64
    let bitrate: Int?
    let duration: Int?
    let remotePath: String

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}
