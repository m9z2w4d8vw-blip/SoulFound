import SwiftUI

struct SearchView: View {
    @EnvironmentObject var client: SoulseekClient
    @EnvironmentObject var searchManager: SearchManager
    @EnvironmentObject var downloadManager: DownloadManager

    @State private var query = ""
    @State private var showLogin = false

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
                    List(searchManager.results) { result in
                        SearchResultRow(result: result) {
                            downloadManager.enqueue(result)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("SoulFound")
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
                Text(result.filename)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(result.username)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(result.formattedSize)
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
                    SecureField("Password", text: $password)
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
        ShareLink(item: DebugLog.shared.fileURL) {
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
