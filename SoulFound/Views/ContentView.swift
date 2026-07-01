import SwiftUI

struct ContentView: View {
    @StateObject private var client = SoulseekClient()
    @StateObject private var searchManager = SearchManager()
    @StateObject private var downloadManager = DownloadManager()
    @StateObject private var settings = AppSettings()

    var body: some View {
        TabView {
            SearchView()
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }
            DownloadsView()
                .tabItem {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .environmentObject(client)
        .environmentObject(searchManager)
        .environmentObject(downloadManager)
        .environmentObject(settings)
        .preferredColorScheme(settings.isLightMode ? .light : .dark)
        .task {
            searchManager.attach(to: client)
            downloadManager.attach(to: client, settings: settings)

            // Stay logged in like the desktop client: if we have saved
            // credentials, reconnect automatically on launch rather than
            // showing the login sheet. Logging out (Settings) is what clears
            // these, so a silent failure here (e.g. bad saved password)
            // just leaves the "Tap to log in" banner for the user to retry.
            if let saved = KeychainHelper.loadSavedCredentials() {
                DebugLog.shared.log("Attempting auto-login for \(saved.username)")
                try? await client.connect(username: saved.username, password: saved.password)
            }
        }
    }
}