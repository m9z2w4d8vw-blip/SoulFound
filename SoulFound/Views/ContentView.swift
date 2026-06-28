import SwiftUI

struct ContentView: View {
    @StateObject private var client = SoulseekClient()
    @StateObject private var searchManager = SearchManager()
    @StateObject private var downloadManager = DownloadManager()

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
        }
        .environmentObject(client)
        .environmentObject(searchManager)
        .environmentObject(downloadManager)
    }
}
