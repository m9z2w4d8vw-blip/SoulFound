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
            case .downloading(let progress):
                ProgressView(value: progress)
                    .tint(.blue)
                Text("\(Int(progress * 100))%")
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
}
