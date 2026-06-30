import Foundation
import Combine

@MainActor
class SearchManager: ObservableObject {
    @Published var results: [SearchResult] = []
    @Published var isSearching = false

    private var currentToken: UInt32?
    private var searchTask: Task<Void, Never>?
    private var cancellable: AnyCancellable?
    private weak var client: SoulseekClient?

    func attach(to client: SoulseekClient) {
        self.client = client
        cancellable = client.$searchResultsByToken
            .receive(on: RunLoop.main)
            .sink { [weak self] allResults in
                guard let self, let token = self.currentToken else { return }
                if let results = allResults[token] {
                    self.results = results
                }
            }
    }

    func search(query: String) async {
        guard let client else { return }

        // Cancel any in-flight search before starting a new one
        searchTask?.cancel()

        isSearching = true
        results = []

        let token = client.search(query: query)
        currentToken = token

        searchTask = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if !Task.isCancelled {
                isSearching = false
            }
        }

        await searchTask?.value
    }
}