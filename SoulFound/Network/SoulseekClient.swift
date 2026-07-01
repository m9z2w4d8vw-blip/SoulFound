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
    private var peerAddressContinuations: [String: [CheckedContinuation<(ip: UInt32, port: UInt16), Error>]] = [:]

    let peerManager = PeerConnectionManager()

    init() {
        peerManager.onSearchResults = { [weak self] results, token in
            self?.searchResultsByToken[token, default: []].append(contentsOf: results)
            DebugLog.shared.log("Stored \(results.count) results under token:\(token), total now:\(self?.searchResultsByToken[token]?.count ?? 0)")
        }
    }

    // MARK: - Public API

    func connect(username: String, password: String) async throws {
        DebugLog.shared.log("BUILD v0.7.0 - resync-safe server message parser")
        disconnect()

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
    /// Clears any previous entry under this token (defensive — tokens are random so
    /// collisions are astronomically unlikely, but this guarantees a clean slate).
    func search(query: String) -> UInt32 {
        let token = UInt32.random(in: 1...(UInt32.max - 1))
        searchResultsByToken[token] = []

        var body = Data()
        body.appendUInt32(token)
        body.appendSlskString(query)
        send(buildMessage(code: 26, body: body)) // FileSearch
        DebugLog.shared.log("Sent FileSearch query:\"\(query)\" token:\(token)")
        return token
    }

    /// Clears stored results for a token. Call this when a search's UI lifecycle ends
    /// so old entries don't pile up in memory across many searches in one session.
    func clearSearchResults(for token: UInt32) {
        searchResultsByToken.removeValue(forKey: token)
    }

    /// Asks the server for a peer's IP/port so we can dial them directly — used
    /// when we (not they) are the one initiating a connection, e.g. to request
    /// a download. See GetPeerAddress (server code 3) in SLSKPROTOCOL.html.
    func getPeerAddress(username: String) async throws -> (ip: UInt32, port: UInt16) {
        guard isConnected else { throw SoulseekError.notConnected }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(ip: UInt32, port: UInt16), Error>) in
            peerAddressContinuations[username, default: []].append(cont)
            var body = Data()
            body.appendSlskString(username)
            send(buildMessage(code: 3, body: body))
        }
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

    /// Known-valid server message codes. Anything outside this set combined with an
    /// implausible size is treated as a desync signal, not a real message.
    private static let knownServerCodes: Set<UInt32> = [
        1, 2, 3, 5, 7, 13, 14, 15, 16, 18, 22, 23, 26, 28, 32, 33, 34, 35, 36, 41,
        42, 51, 52, 54, 56, 57, 58, 60, 62, 63, 64, 65, 66, 67, 68, 69, 71, 83, 84,
        86, 87, 88, 90, 91, 92, 100, 102, 103, 104, 110, 111, 112, 113, 114, 115,
        116, 117, 118, 120, 121, 122, 123, 124, 125, 126, 127, 129, 130, 133, 134,
        135, 136, 137, 138, 139, 140, 141, 142, 143, 144, 145, 148, 149, 150, 151,
        152, 153, 160, 1001
    ]

    /// Parses every complete message in the buffer and dispatches it via handleMessage.
    ///
    /// Every slice is bounds-checked before use. Critically, this also guards against
    /// *stream desync*: if a length prefix looks implausible for a real Soulseek server
    /// message (either absurdly large, or paired with a message code we don't recognize),
    /// we don't trust it — instead of blindly waiting for however many bytes that bogus
    /// length claims, we drop a single byte and retry parsing from the next offset. This
    /// lets the parser self-resync onto the next real message boundary instead of getting
    /// permanently misaligned and producing garbage codes for the rest of the connection.
    private func processBuffer() {
        // Make contiguous to avoid subscript traps on sliced Data
        var buf = Data(receiveBuffer)
        receiveBuffer = Data()

        while buf.count >= 4 {
            let b0 = UInt32(buf[buf.startIndex])
            let b1 = UInt32(buf[buf.startIndex + 1])
            let b2 = UInt32(buf[buf.startIndex + 2])
            let b3 = UInt32(buf[buf.startIndex + 3])
            let msgLength = Int(b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))

            // A real message is at minimum 4 bytes (just the code, no body).
            // Cap sanity-checked size at 2MB — generously larger than any real
            // Soulseek server message (RoomList, the biggest, is usually <20KB),
            // but small enough that garbage lengths get rejected fast instead of
            // stalling the parser waiting for data that'll never arrive as one block.
            guard msgLength >= 4, msgLength <= 2_000_000 else {
                DebugLog.shared.log("Desync suspected: implausible length \(msgLength), resyncing by 1 byte")
                buf = Data(buf.dropFirst(1))
                continue
            }

            let totalNeeded = 4 + msgLength
            guard buf.count >= totalNeeded else {
                receiveBuffer = buf  // save remainder, wait for more data
                return
            }

            guard buf.count >= 8 else {
                buf = Data(buf.dropFirst(totalNeeded))
                continue
            }

            let c0 = UInt32(buf[buf.startIndex + 4])
            let c1 = UInt32(buf[buf.startIndex + 5])
            let c2 = UInt32(buf[buf.startIndex + 6])
            let c3 = UInt32(buf[buf.startIndex + 7])
            let code = c0 | (c1 << 8) | (c2 << 16) | (c3 << 24)

            // Second line of defense: if the code isn't one we recognize AND the
            // claimed size is suspiciously large, this is very likely a desynced
            // read rather than a genuine unknown message. Resync by 1 byte instead
            // of consuming (and thereby trusting) this framing.
            if !Self.knownServerCodes.contains(code) && msgLength > 4096 {
                DebugLog.shared.log("Desync suspected: unknown code \(code) with size \(msgLength), resyncing by 1 byte")
                buf = Data(buf.dropFirst(1))
                continue
            }

            let body = totalNeeded > 8 ? Data(buf[(buf.startIndex + 8)..<(buf.startIndex + totalNeeded)]) : Data()
            buf = Data(buf.dropFirst(totalNeeded))
            handleMessage(code: code, body: body)
        }

        // Preserve any leftover partial bytes (fewer than 4) for the next receive.
        if !buf.isEmpty {
            receiveBuffer = buf
        }
    }

    private func handleMessage(code: UInt32, body: Data) {
        DebugLog.shared.log("Server message code: \(code), size: \(body.count)")
        switch code {
        case 1:
            handleLoginResponse(body: body)
        case 3:
            handleGetPeerAddress(body: body)
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

    // MARK: - GetPeerAddress (server code 3)

    /// Resolves a peer's IP/port so we can dial out to them directly (used when
    /// initiating a download). See GetPeerAddress in SLSKPROTOCOL.html: username,
    /// ip, port, obfuscation type, obfuscated port — we only need ip/port.
    private func handleGetPeerAddress(body: Data) {
        var offset = 0
        guard let username = body.readSlskString(at: &offset) else { return }
        guard offset + 4 <= body.count else { return }
        let ip = body.readUInt32(at: offset); offset += 4
        guard offset + 4 <= body.count else { return }
        let port = body.readUInt32(at: offset)

        guard var conts = peerAddressContinuations[username], !conts.isEmpty else { return }
        let cont = conts.removeFirst()
        peerAddressContinuations[username] = conts.isEmpty ? nil : conts
        cont.resume(returning: (ip: ip, port: UInt16(truncatingIfNeeded: port)))
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
            peerUsername: peerUsername,
            type: type
        )
    }
}