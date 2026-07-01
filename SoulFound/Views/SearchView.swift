import SwiftUI

struct SearchView: View {
    @EnvironmentObject var client: SoulseekClient
    @EnvironmentObject var searchManager: SearchManager
    @EnvironmentObject var downloadManager: DownloadManager

    @State private var query = ""
    @State private var showLogin = false
    @State private var sortField: SortField = .none
    @State private var sortAscending = true
    @State private var expandedFolders: Set<String> = []

    /// Sorted view over the current results. `.none` preserves the order results
    /// arrived in from peers (i.e. "Best Match" on the desktop client).
    private var sortedResults: [SearchResult] {
        let results = searchManager.results
        let sorted: [SearchResult]
        switch sortField {
        case .none:
            return results
        case .file:
            sorted = results.sorted {
                $0.displayFilename.localizedStandardCompare($1.displayFilename) == .orderedAscending
            }
        case .size:
            sorted = results.sorted { $0.size < $1.size }
        case .attributes:
            // Bitrate first (files with no bitrate info sort last), then duration as a tiebreaker.
            sorted = results.sorted { lhs, rhs in
                let l = lhs.bitrate ?? -1
                let r = rhs.bitrate ?? -1
                if l != r { return l < r }
                return (lhs.duration ?? -1) < (rhs.duration ?? -1)
            }
        case .speed:
            // Peers with no reported speed sort last, matching the .attributes convention above.
            sorted = results.sorted { ($0.uploadSpeed ?? -1) < ($1.uploadSpeed ?? -1) }
        }
        return sortAscending ? sorted : sorted.reversed()
    }

    /// Groups results by (username, folder) — exactly what the desktop client's
    /// "Folder" column represents. A search like "Born To Die" can hit both a
    /// single loose track (its own folder, one file) and a whole album shared
    /// by another user (same folder, a dozen+ files); grouping makes that
    /// distinction visible instead of dumping every file into one flat list
    /// with no indication of what actually ships together.
    ///
    /// Only used in "Best Match" order (sortField == .none). Once the user
    /// picks an explicit sort (File/Size/Attributes/Speed) they're asking for a
    /// flat, file-level ranking — scattering that across folder cards would
    /// undo the sort, so `sortedResults` is shown as a plain list instead.
    private var groupedResults: [ResultGroup] {
        var order: [String] = []
        var buckets: [String: [SearchResult]] = [:]
        for result in searchManager.results {
            let key = "\(result.username)\u{0}\(result.displayFolder)"
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(result)
        }
        return order.compactMap { key in
            guard let files = buckets[key], let first = files.first else { return nil }
            if files.count > 1 {
                return .folder(id: key, username: first.username, folder: first.displayFolder, files: files)
            } else {
                return .single(first)
            }
        }
    }

    private func toggleExpanded(_ id: String) {
        if expandedFolders.contains(id) {
            expandedFolders.remove(id)
        } else {
            expandedFolders.insert(id)
        }
    }

    /// Tapping a chip cycles: off → ascending → descending → off. Tapping a
    /// different field starts it fresh at ascending — same feel as clicking a
    /// column header in the desktop client.
    private func toggleSort(_ field: SortField) {
        if sortField != field {
            sortField = field
            sortAscending = true
        } else if sortAscending {
            sortAscending = false
        } else {
            sortField = .none
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !client.isConnected {
                    Button("Tap to log in") { showLogin = true }
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(Color.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }

                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search for music, files…", text: $query)
                        .submitLabel(.search)
                        .onSubmit { runSearch() }
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding()

                if searchManager.isSearching {
                    ProgressView("Searching…")
                        .padding(.top, 40)
                    Spacer()
                } else if searchManager.results.isEmpty && !query.isEmpty {
                    ContentUnavailableView("No results", systemImage: "doc.magnifyingglass", description: Text("Try a different search term"))
                    Spacer()
                } else {
                    if !searchManager.results.isEmpty {
                        SortBar(sortField: sortField, sortAscending: sortAscending, toggle: toggleSort)
                    }
                    List {
                        if sortField == .none {
                            ForEach(groupedResults) { group in
                                switch group {
                                case .folder(_, let username, let folder, let files):
                                    FolderGroupRow(
                                        username: username,
                                        folder: folder,
                                        files: files,
                                        isExpanded: expandedFolders.contains(group.id),
                                        onToggle: { toggleExpanded(group.id) },
                                        onDownloadAll: { downloadManager.enqueueFolder(files) },
                                        onDownloadFile: { downloadManager.enqueue($0) }
                                    )
                                case .single(let result):
                                    SearchResultRow(result: result) {
                                        downloadManager.enqueue(result)
                                    }
                                }
                            }
                        } else {
                            ForEach(sortedResults) { result in
                                SearchResultRow(result: result) {
                                    downloadManager.enqueue(result)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("SoulFound")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: DebugLog.shared.fileURLPublic) {
                        Image(systemName: "doc.text")
                    }
                }
            }
            .sheet(isPresented: $showLogin) {
                LoginSheet()
            }
        }
    }

    private func runSearch() {
        guard client.isConnected, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            showLogin = true
            return
        }
        Task { await searchManager.search(query: query) }
    }
}

struct SearchResultRow: View {
    let result: SearchResult
    let onDownload: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(result.displayFilename)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(result.username)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(result.formattedSize)
                    if result.bitrate != nil || result.duration != nil {
                        Text("•")
                        Text(result.formattedAttributes)
                    }
                    if result.uploadSpeed != nil {
                        Text("•")
                        Text("\(result.formattedSpeed) KB/s")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(action: onDownload) {
                Image(systemName: "arrow.down.circle")
                    .font(.title2)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

/// A row in the grouped ("Best Match") search view: either several files that
/// share the same user+folder — an album, typically — or a single ungrouped
/// file that didn't share its folder with anything else in these results.
private enum ResultGroup: Identifiable {
    case folder(id: String, username: String, folder: String, files: [SearchResult])
    case single(SearchResult)

    var id: String {
        switch self {
        case .folder(let id, _, _, _): return id
        case .single(let result): return result.id.uuidString
        }
    }
}

/// Collapsible card for a folder containing multiple files from one peer —
/// e.g. a whole shared album. Tapping the header expands/collapses the file
/// list; "All" queues every file in the folder in one tap, mirroring the
/// desktop client's "Download Folder" action.
struct FolderGroupRow: View {
    let username: String
    let folder: String
    let files: [SearchResult]
    let isExpanded: Bool
    let onToggle: () -> Void
    let onDownloadAll: () -> Void
    let onDownloadFile: (SearchResult) -> Void

    /// Soulseek folder paths are the full remote chain (e.g.
    /// "Lana Del Rey/!pop-rnb-blues/mu/Born to Die (2012)"), backslash-separated
    /// regardless of the sharer's OS. Showing just the last component ("Born to
    /// Die (2012)") is what people actually recognize as the album name.
    private var folderDisplayName: String {
        let normalized = folder.replacingOccurrences(of: "\\", with: "/")
        let name = (normalized as NSString).lastPathComponent
        return name.isEmpty ? folder : name
    }

    private var formattedTotalSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: files.reduce(0) { $0 + $1.size })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.orange)
                        .font(.title3)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(folderDisplayName)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(username)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(files.count) files • \(formattedTotalSize)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onDownloadAll) {
                Label("Download folder (\(files.count) files)", systemImage: "arrow.down.circle.fill")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .padding(.leading, 30)
            .padding(.top, 6)

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(files) { file in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.displayFilename)
                                    .font(.caption)
                                    .lineLimit(1)
                                Text(file.formattedSize)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button {
                                onDownloadFile(file)
                            } label: {
                                Image(systemName: "arrow.down.circle")
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(.leading, 30)
                .padding(.top, 8)
            }
        }
        .padding(.vertical, 6)
    }
}

/// What a search result list can be sorted by. `.none` means "as received" (the
/// desktop client's "Best Match" / unsorted order).
enum SortField: String, CaseIterable {
    case none
    case file = "File"
    case size = "Size"
    case attributes = "Attributes"
    case speed = "Speed"
}

/// Row of tappable chips mirroring the desktop client's sortable column headers.
/// Tapping cycles a field through ascending → descending → off.
struct SortBar: View {
    let sortField: SortField
    let sortAscending: Bool
    let toggle: (SortField) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Sort:")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach([SortField.file, .size, .attributes, .speed], id: \.self) { field in
                chip(field)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func chip(_ field: SortField) -> some View {
        let isActive = sortField == field
        return Button {
            toggle(field)
        } label: {
            HStack(spacing: 4) {
                Text(field.rawValue)
                if isActive {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isActive ? Color.blue.opacity(0.15) : Color(.secondarySystemBackground))
            .foregroundStyle(isActive ? .blue : .primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct LoginSheet: View {
    @EnvironmentObject var client: SoulseekClient
    @Environment(\.dismiss) var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var isLoggingIn = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Soulseek account") {
                    TextField("Username", text: $username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .textContentType(.username)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                }
                if let error = errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
                Section {
                    Button(isLoggingIn ? "Logging in…" : "Log in") {
                        Task { await login() }
                    }
                    .disabled(username.isEmpty || password.isEmpty || isLoggingIn)
                }
            }
            .navigationTitle("Log in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: DebugLog.shared.fileURLPublic) {
                        Image(systemName: "doc.text")
                    }
                }
            }
        }
    }

    private func login() async {
        isLoggingIn = true
        errorMessage = nil
        do {
            try await client.connect(username: username, password: password)
            KeychainHelper.save(username: username, password: password)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoggingIn = false
    }
}