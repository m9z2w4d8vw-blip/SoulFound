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

    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var loginContinuation: CheckedContinuation<Void, Error>?

    // MARK: - Public API

    func connect(username: String, password: String) async throws {
        disconnect()

        let host = NWEndpoint.Host(Server.host)
        let port = NWEndpoint.Port(rawValue: Server.port)!
        let conn = NWConnection(host: host, port: port, using: .tcp)
        self.connection = conn

        // Wait for TCP connection to become ready
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

        // Send Login and wait for server response
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
        // SetListenPort (2) — port 0, no uploads
        var portBody = Data()
        portBody.appendUInt32(0)
        send(buildMessage(code: 2, body: portBody))

        // SetStatus (28) — 1 = online
        var statusBody = Data()
        statusBody.appendUInt32(1)
        send(buildMessage(code: 28, body: statusBody))

        // SharedFoldersFiles (35) — 0 dirs, 0 files
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
            // Hop back to MainActor so we can safely touch @MainActor state
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

    private func processBuffer() {
        receiveBuffer.removeAll()
    }

        receiveBuffer = buf
    }

    private func handleMessage(code: UInt32, body: Data) {
        switch code {
        case 1: handleLoginResponse(body: body)
        default: break
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
}

// MARK: - Data helpers

private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        let le = value.littleEndian
        append(UInt8((le >> 0)  & 0xFF))
        append(UInt8((le >> 8)  & 0xFF))
        append(UInt8((le >> 16) & 0xFF))
        append(UInt8((le >> 24) & 0xFF))
    }

    mutating func appendSlskString(_ string: String) {
        let bytes = string.data(using: .utf8) ?? Data()
        appendUInt32(UInt32(bytes.count))
        append(bytes)
    }

    func readUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let b0 = UInt32(self[offset])
        let b1 = UInt32(self[offset + 1])
        let b2 = UInt32(self[offset + 2])
        let b3 = UInt32(self[offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    func readSlskString(at offset: inout Int) -> String? {
        guard offset + 4 <= count else { return nil }
        let len = Int(readUInt32(at: offset))
        offset += 4
        guard offset + len <= count else { return nil }
        let str = String(data: subdata(in: offset..<offset+len), encoding: .utf8)
        offset += len
        return str
    }
}