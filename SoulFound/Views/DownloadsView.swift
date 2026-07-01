import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject var downloadManager: DownloadManager

    var body: some View {
        NavigationStack {
            Group {
                if downloadManager.downloads.isEmpty {
                    ContentUnavailableView(
                        "No downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Files you download will appear here")
                    )
                } else {
                    List(downloadManager.downloads) { item in
                        DownloadRow(item: item)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Downloads")
        }
    }
}

struct DownloadRow: View {
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.filename)
                .font(.subheadline)
                .lineLimit(2)
            Text(item.username)
                .font(.caption)
                .foregroundStyle(.secondary)

            switch item.state {
            case .queued:
                Text("Queued")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .downloading(let progress, let speed):
                ProgressView(value: progress)
                    .tint(.blue)
                HStack {
                    Text("\(Int(progress * 100))%")
                    Text("•")
                    Text(formattedSpeed(speed))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            case .completed:
                Label("Saved to Files", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    /// Formats bytes/sec as KB/s or MB/s, matching the precision the search
    /// list uses for peer upload speed (one decimal place).
    private func formattedSpeed(_ bytesPerSec: Double) -> String {
        let kbPerSec = bytesPerSec / 1024
        if kbPerSec >= 1024 {
            return String(format: "%.1f MB/s", kbPerSec / 1024)
        }
        return String(format: "%.1f KB/s", kbPerSec)
    }
}