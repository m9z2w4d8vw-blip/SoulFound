import Foundation
import Network
import CryptoKit

// MARK: - Server constants
private enum Server {
    static let host = "server.slsknet.org"
    static let port: UInt16 = 2242
    static let clientVersion: UInt32 = 160
    static let minorVersion: UInt32 = 1
}

// MARK: - Errors
enum SoulseekError: LocalizedError {
    case connectionFailed(String)
    case loginFailed(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .loginFailed(let msg):     return "Login failed: \(msg)"
        case .notConnected:             return "Not connected to Soulseek"
        }
    }
}

// MARK: - SoulseekClient
@MainActor
class SoulseekClient: ObservableObject {
    @Published var isConnected = false
    @Published var username: String = ""

    /// Search results received so far, keyed by the token returned from `search(query:)`.
    /// SearchManager observes this and filters by its own current token.
    @Published var searchResultsByToken: [UInt32: [SearchResult]] = [:]

    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var loginContinuation: CheckedContinuation<Void, Error>?

    let peerManager = PeerConnectionManager()

    init() {
        peerManager.onSearchResults = { [weak self] results, token in
            self?.searchResultsByToken[token, default: []].append(contentsOf: results)
        }
    }

    // MARK: - Public API

    func connect(username: String, password: String) async throws {
    DebugLog.shared.log("BUILD v0.3.8 - IP fix active")
    disconnect()
    // ...rest of function

        let host = NWEndpoint.Host(Server.host)
        let port = NWEndpoint.Port(rawValue: Server.port)!
        let conn = NWConnection(host: host, port: port, using: .tcp)
        self.connection = conn

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    cont.resume()
                case .failed(let error):
                    cont.resume(throwing: SoulseekError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    cont.resume(throwing: SoulseekError.connectionFailed("Connection cancelled"))
                default:
                    break
                }
            }
            conn.start(queue: .main)
        }

        startReceiving()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.loginContinuation = cont
            do {
                try sendLogin(username: username, password: password)
            } catch {
                self.loginContinuation = nil
                cont.resume(throwing: error)
            }
        }

        self.username = username
        self.isConnected = true

        peerManager.startListening()
        sendPostLoginMessages()
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
        username = ""
        receiveBuffer = Data()
        loginContinuation = nil
    }

    /// Sends a global file search. Returns the token to watch in `searchResultsByToken`.
    func search(query: String) -> UInt32 {
        let token = UInt32.random(in: 1...(UInt32.max - 1))
        var body = Data()
        body.appendUInt32(token)
        body.appendSlskString(query)
        send(buildMessage(code: 26, body: body)) // FileSearch
        return token
    }

    // MARK: - Login message (Server code 1)

    private func sendLogin(username: String, password: String) throws {
        let md5Input = (username + password).data(using: .utf8)!
        let hash = Insecure.MD5.hash(data: md5Input)
        let md5String = hash.map { String(format: "%02x", $0) }.joined()

        var body = Data()
        body.appendSlskString(username)
        body.appendSlskString(password)
        body.appendUInt32(Server.clientVersion)
        body.appendSlskString(md5String)
        body.appendUInt32(Server.minorVersion)

        send(buildMessage(code: 1, body: body))
    }

    // MARK: - Post-login messages

    private func sendPostLoginMessages() {
        // SetWaitPort — tell the server which port we're listening on for incoming
        // peer connections. Note: on a phone with no port forwarding, this port
        // usually isn't reachable from the internet. Peers who can't reach it directly
        // will trigger a ConnectToPeer (code 18) message instead, which we handle below
        // by dialing out ourselves — that's the path that actually works without
        // port forwarding.
        var portBody = Data()
        portBody.appendUInt32(UInt32(peerManager.listenPort))
        send(buildMessage(code: 2, body: portBody))

        var statusBody = Data()
        statusBody.appendUInt32(1)
        send(buildMessage(code: 28, body: statusBody))

        var shareBody = Data()
        shareBody.appendUInt32(0)
        shareBody.appendUInt32(0)
        send(buildMessage(code: 35, body: shareBody))
    }

    // MARK: - Message builder

    private func buildMessage(code: UInt32, body: Data) -> Data {
        var msg = Data()
        msg.appendUInt32(UInt32(4 + body.count))
        msg.appendUInt32(code)
        msg.append(body)
        return msg
    }

    private func send(_ data: Data) {
        connection?.send(content: data, completion: .idempotent)
    }

    // MARK: - Receive loop

    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data {
                    self.receiveBuffer.append(data)
                    self.processBuffer()
                }
                if error != nil { return }
                if isComplete { self.disconnect(); return }
                self.startReceiving()
            }
        }
    }

    /// Parses every complete message in the buffer and dispatches it via handleMessage.
    /// Every slice is bounds-checked before use — no operation here should ever be able
    /// to trap, even on a fully desynced/garbage stream (worst case: we clear the buffer
    /// and wait for the connection to resync naturally on the next message boundary).
    private func processBuffer() {
    // Make contiguous to avoid subscript traps on sliced Data
    var buf = Data(receiveBuffer)
    receiveBuffer = Data()

    while buf.count >= 4 {
        let b0 = UInt32(buf[0])
        let b1 = UInt32(buf[1])
        let b2 = UInt32(buf[2])
        let b3 = UInt32(buf[3])
        let msgLength = Int(b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))

        guard msgLength >= 4, msgLength <= 50_000_000 else {
            return
        }

        let totalNeeded = 4 + msgLength
        guard buf.count >= totalNeeded else {
            receiveBuffer = buf  // save remainder
            return
        }

        let code: UInt32
        if buf.count >= 8 {
            let c0 = UInt32(buf[4])
            let c1 = UInt32(buf[5])
            let c2 = UInt32(buf[6])
            let c3 = UInt32(buf[7])
            code = c0 | (c1 << 8) | (c2 << 16) | (c3 << 24)
        } else {
            buf = Data(buf.dropFirst(totalNeeded))
            continue
        }

        let body = totalNeeded > 8 ? Data(buf[8..<totalNeeded]) : Data()
        buf = Data(buf.dropFirst(totalNeeded))
        handleMessage(code: code, body: body)
    }
}

    private func handleMessage(code: UInt32, body: Data) {
    DebugLog.shared.log("Server message code: \(code), size: \(body.count)")
    switch code {
    case 1:
        handleLoginResponse(body: body)
    case 18:
        DebugLog.shared.log("ConnectToPeer received")
        handleConnectToPeer(body: body)
    default:
        break
    }
}

    // MARK: - Login response

    private func handleLoginResponse(body: Data) {
        guard body.count >= 1 else {
            loginContinuation?.resume(throwing: SoulseekError.loginFailed("Empty response"))
            loginContinuation = nil
            return
        }
        let success = body[0] != 0
        if success {
            loginContinuation?.resume()
        } else {
            var offset = 1
            let reason = body.readSlskString(at: &offset) ?? "Bad Password"
            loginContinuation?.resume(throwing: SoulseekError.loginFailed(reason))
        }
        loginContinuation = nil
    }

    // MARK: - ConnectToPeer (server code 18)

    /// The server sends this when another user wants to connect to us (e.g. to deliver
    /// search results or request a file) but couldn't reach us directly. We respond by
    /// dialing out to them ourselves and sending PierceFireWall with the matching token.
    private func handleConnectToPeer(body: Data) {
    var offset = 0
    guard let peerUsername = body.readSlskString(at: &offset) else { return }
    guard let type = body.readSlskString(at: &offset) else { return }
    guard offset + 4 <= body.count else { return }
    let ip = body.readUInt32(at: offset); offset += 4
    let ipStr = "\(ip & 0xFF).\((ip >> 8) & 0xFF).\((ip >> 16) & 0xFF).\((ip >> 24) & 0xFF)"
    DebugLog.shared.log("Raw IP uint32:\(ip) → \(ipStr) for \(peerUsername)")
    guard offset + 4 <= body.count else { return }
    let port = body.readUInt32(at: offset); offset += 4
    guard offset + 4 <= body.count else { return }
    let token = body.readUInt32(at: offset); offset += 4

    // "P" = peer connection (search results, etc), "F" = file transfer.
    // "D" (distributed network) is out of scope for a download-only client.
    guard type == "P" || type == "F" else { return }

    peerManager.connectOut(
        toIP: ip,
        port: UInt16(truncatingIfNeeded: port),
        token: token,
        peerUsername: peerUsername
    )
}
}