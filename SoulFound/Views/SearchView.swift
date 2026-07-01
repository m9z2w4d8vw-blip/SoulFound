import SwiftUI

struct SearchView: View {
    @EnvironmentObject var client: SoulseekClient
    @EnvironmentObject var searchManager: SearchManager
    @EnvironmentObject var downloadManager: DownloadManager

    @State private var query = ""
    @State private var showLogin = false
    @State private var sortField: SortField = .none
    @State private var sortAscending = true

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
                    List(sortedResults) { result in
                        SearchResultRow(result: result) {
                            downloadManager.enqueue(result)
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
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoggingIn = false
    }
}