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

    /// Soulseek's filename field is actually the whole remote path (folder included,
    /// backslash-separated Windows-style regardless of the sending peer's OS). This pulls
    /// out just the last component, matching what the desktop client shows in its "File"
    /// column (as opposed to "Folder").
    var displayFilename: String {
        let normalized = filename.replacingOccurrences(of: "\\", with: "/")
        let name = (normalized as NSString).lastPathComponent
        return name.isEmpty ? filename : name
    }

    /// The folder portion of the remote path, matching the desktop client's "Folder" column.
    var displayFolder: String {
        let normalized = filename.replacingOccurrences(of: "\\", with: "/")
        return (normalized as NSString).deletingLastPathComponent
    }

    /// Matches the desktop client's "Attributes" column, e.g. "320kbps, 4m31s".
    var formattedAttributes: String {
        var parts: [String] = []
        if let bitrate { parts.append("\(bitrate)kbps") }
        if let duration {
            let minutes = duration / 60
            let seconds = duration % 60
            parts.append("\(minutes)m\(String(format: "%02d", seconds))s")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: ", ")
    }
}