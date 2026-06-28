import Foundation
import Network

private enum ServerHost {
    static let host = "server.slsknet.org"
    static let port: UInt16 = 2242
}

enum SoulseekError: LocalizedError {
    case connectionFailed(String)
    case loginFailed(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .loginFailed(let msg): return "Login failed: \(msg)"
        case .notConnected: return "Not connected to Soulseek"
        }
    }
}

@MainActor
class SoulseekClient: ObservableObject {
    @Published var isConnected = false
    @Published var username: String = ""

    private var connection: NWConnection?

    // TODO (Phase 4): implement real TCP login
    func connect(username: String, password: String) async throws {
        throw SoulseekError.connectionFailed("Login not yet implemented — coming in phase 4")
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
        username = ""
    }
}
