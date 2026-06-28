import Foundation

@MainActor
class SearchManager: ObservableObject {
    @Published var results: [SearchResult] = []
    @Published var isSearching = false

    // TODO (Phase 5): implement FileSearch message (code 26)
    func search(query: String) async {
        isSearching = true
        results = []
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        isSearching = false
    }
}
