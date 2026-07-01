import Foundation
import Network

/// Implements the download side of the Soulseek transfer flow described in
/// SLSKPROTOCOL.html ("Example Flow for Downloading a File") and the aioslsk
/// "Transfer Flows / Basic Flow" doc:
///
///   1. We dial the peer directly and send PeerInit (type "P").
///   2. We send QueueUpload (peer code 43) with the file's remote path.
///   3. The peer replies with TransferRequest (peer code 40): a ticket + filesize.
///   4. We reply with TransferResponse (peer code 41), allowed = true.
///   5. The peer opens a new 'F' connection to us (indirectly, via the server —
///      handled by SoulseekClient/PeerConnectionManager same as inbound search
///      results) and sends the ticket again as the first 4 raw bytes.
///   6. We reply with an 8-byte FileOffset (always 0 — no resume support here).
///   7. The peer streams the file; we write it to Documents and close the
///      connection ourselves once we've received `filesize` bytes.
///
/// Because this app has no reachable listening port, only the *direct*
/// connection method is attempted for step 1. If a peer can't be reached
/// directly, the download fails — there's no way for them to reach us back
/// for the initial P connection either.
///
/// Concurrency: each in-flight request to a peer gets its own NWConnection and
/// its own downloadID/remotePath threaded through the closures that handle it
/// (rather than a shared username-keyed dict), so multiple simultaneous
/// downloads from the same peer — e.g. "Download Folder" queuing 16 tracks at
/// once — don't clobber each other's session state. `requestQueue`/`activeCount`
/// below just bound *how many* of those run at once per peer.
@MainActor
final class TransferManager {

    private struct Session {
        let downloadID: UUID
        let username: String
        let remotePath: String
        var fileSize: UInt64 = 0
        var bytesReceived: UInt64 = 0
        var fileHandle: FileHandle?
        var destinationURL: URL?
        /// Set when the destination folder came from a user-picked (non-sandbox)
        /// location, so we know to balance the access call when the transfer
        /// ends (success, failure, or cancellation).
        var securityScopedFolderURL: URL?

        // Speed tracking: recomputed at most every 0.5s from the bytes/time
        // delta since the last computation, rather than per-chunk, since
        // chunk sizes/arrival timing are too jittery for a readable number.
        var speedWindowStart: Date = Date()
        var speedWindowStartBytes: UInt64 = 0
        var currentSpeed: Double = 0
    }

    /// A request that's been asked for but hasn't started connecting yet.
    private struct QueuedRequest {
        let downloadID: UUID
        let remotePath: String
    }

    /// Sessions that have received TransferRequest and are waiting for the
    /// matching file ('F') connection to arrive. Keyed by the transfer ticket,
    /// which is globally unique (assigned by the peer), so this is safe even
    /// with several transfers to the same peer in flight simultaneously.
    private var pendingByTicket: [UInt32: Session] = [:]

    /// Requests waiting for a free concurrency slot, per peer.
    private var requestQueue: [String: [QueuedRequest]] = [:]

    /// How many in-flight transfers (P connection open through the very end of
    /// the F connection) we allow to the same peer at once. A folder download
    /// can queue dozens of files instantly; without a cap we'd try to open that
    /// many raw TCP connections to one peer simultaneously, which is both
    /// antisocial to the peer and a good way to trip mobile network connection
    /// limits. Requests past the cap just sit in `requestQueue` and start as
    /// earlier ones finish — that's exactly the existing "Queued" state, so no
    /// new UI concept was needed for it.
    private let maxConcurrentPerPeer = 3
    private var activeCount: [String: Int] = [:]

    /// Fired whenever a download's state changes so DownloadManager can update the UI.
    var onStateChange: ((UUID, DownloadState) -> Void)?

    private weak var client: SoulseekClient?
    private let peerManager: PeerConnectionManager
    private let settings: AppSettings

    init(client: SoulseekClient, peerManager: PeerConnectionManager, settings: AppSettings) {
        self.client = client
        self.peerManager = peerManager
        self.settings = settings
        peerManager.onIncomingFileConnection = { [weak self] connectionToken, conn in
            self?.beginReceivingFile(connectionToken: connectionToken, conn: conn)
        }
    }

    // MARK: - Public API

    func startDownload(id: UUID, username: String, remotePath: String) {
        onStateChange?(id, .queued)
        requestQueue[username, default: []].append(QueuedRequest(downloadID: id, remotePath: remotePath))
        pumpQueue(for: username)
    }

    // MARK: - Per-peer concurrency queue

    /// Starts as many queued requests for this peer as the concurrency cap
    /// allows. Called both when new requests are added and whenever an
    /// in-flight one finishes (success or failure), so the next queued file
    /// immediately takes its place.
    private func pumpQueue(for username: String) {
        while (activeCount[username] ?? 0) < maxConcurrentPerPeer {
            guard var queue = requestQueue[username], !queue.isEmpty else { return }
            let next = queue.removeFirst()
            requestQueue[username] = queue.isEmpty ? nil : queue
            activeCount[username, default: 0] += 1

            Task {
                await runDownload(id: next.downloadID, username: username, remotePath: next.remotePath)
            }
        }
    }

    /// Frees this peer's concurrency slot and immediately tries to start the
    /// next queued request for them, if any.
    private func finishSlot(for username: String) {
        activeCount[username] = max(0, (activeCount[username] ?? 1) - 1)
        pumpQueue(for: username)
    }

    private func runDownload(id: UUID, username: String, remotePath: String) async {
        guard let client else {
            finishSlot(for: username)
            return
        }
        do {
            DebugLog.shared.log("Download: resolving address for \(username)")
            let address = try await client.getPeerAddress(username: username)
            guard address.ip != 0, address.port > 0 else {
                throw SoulseekError.connectionFailed("\(username) is not directly reachable")
            }
            try await connectAndRequest(
                id: id,
                ip: address.ip,
                port: address.port,
                myUsername: client.username,
                peerUsername: username,
                remotePath: remotePath
            )
            // connectAndRequest only awaits the P connection reaching TransferRequest
            // territory — the transfer itself continues asynchronously via the
            // incoming F connection (see beginReceivingFile). This peer slot stays
            // occupied until that resolves; appendFileBytes/finishFailed/the P
            // connection's own close handler call finishSlot(for:) once it does.
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            DebugLog.shared.log("Download request failed for \(username): \(reason)")
            onStateChange?(id, .failed(reason: reason))
            finishSlot(for: username)
        }
    }

    // MARK: - P connection: PeerInit, QueueUpload, await TransferRequest

    private func connectAndRequest(id: UUID, ip: UInt32, port: UInt16, myUsername: String, peerUsername: String, remotePath: String) async throws {
        let ipString = "\((ip >> 24) & 0xFF).\((ip >> 16) & 0xFF).\((ip >> 8) & 0xFF).\(ip & 0xFF)"
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw SoulseekError.connectionFailed("Invalid port")
        }
        let conn = NWConnection(host: NWEndpoint.Host(ipString), port: nwPort, using: .tcp)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // `stateUpdateHandler` stays attached for the connection's entire lifetime,
            // not just until we resume — e.g. handleTransferRequest calls conn.cancel()
            // later, which fires this same closure again with .cancelled. Without this
            // guard, that second call to cont.resume() is a fatal error (CheckedContinuation
            // traps on double-resume).
            var hasResumed = false
            conn.stateUpdateHandler = { state in
                Task { @MainActor in
                    guard !hasResumed else { return }
                    switch state {
                    case .ready:
                        hasResumed = true
                        cont.resume()
                    case .failed(let err):
                        hasResumed = true
                        cont.resume(throwing: SoulseekError.connectionFailed(err.localizedDescription))
                    case .cancelled:
                        hasResumed = true
                        cont.resume(throwing: SoulseekError.connectionFailed("Connection cancelled"))
                    default:
                        break
                    }
                }
            }
            conn.start(queue: .main)

            // Watchdog: an unreachable peer can leave the connection sitting in .waiting
            // forever, so resume() never fires and the download is stuck in "Queued".
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !hasResumed else { return }
                hasResumed = true
                conn.cancel()
                cont.resume(throwing: SoulseekError.connectionFailed("Timed out connecting to \(peerUsername)"))
            }
        }

        DebugLog.shared.log("Download: connected directly to \(peerUsername) at \(ipString):\(port)")

        // PeerInit (peer-init code 1): announce ourselves and request a "P" connection.
        var initBody = Data()
        initBody.append(1)
        initBody.appendSlskString(myUsername)
        initBody.appendSlskString("P")
        initBody.appendUInt32(0)
        var initMsg = Data()
        initMsg.appendUInt32(UInt32(initBody.count))
        initMsg.append(initBody)
        conn.send(content: initMsg, completion: .idempotent)

        // QueueUpload (peer code 43): ask the peer to queue this file for us.
        var queueBody = Data()
        queueBody.appendSlskString(remotePath)
        conn.send(content: buildPeerMessage(code: 43, body: queueBody), completion: .idempotent)
        DebugLog.shared.log("Download: sent QueueUpload \"\(remotePath)\" to \(peerUsername)")

        startReceivingPeerMessages(conn: conn, downloadID: id, peerUsername: peerUsername, remotePath: remotePath)
    }

    private func buildPeerMessage(code: UInt32, body: Data) -> Data {
        var msg = Data()
        msg.appendUInt32(UInt32(4 + body.count))
        msg.appendUInt32(code)
        msg.append(body)
        return msg
    }

    private func startReceivingPeerMessages(conn: NWConnection, downloadID: UUID, peerUsername: String, remotePath: String) {
        let box = TransferBufferBox()
        let state = PConnectionState()

        func doReceive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let data {
                        box.data.append(data)
                        self.drainPeerBuffer(box: box, conn: conn, downloadID: downloadID, peerUsername: peerUsername, remotePath: remotePath, state: state)
                    }
                    if error != nil || isComplete {
                        // If this P connection closed without ever handing us a
                        // TransferRequest, the file was never actually queued — e.g.
                        // the peer rejected it, or dropped the connection. Previously
                        // this failed silently (no state change, slot never freed),
                        // which meant one unresponsive peer could permanently stall
                        // part of a folder download.
                        if !state.transferRequestHandled {
                            DebugLog.shared.log("P connection to \(peerUsername) closed before TransferRequest for \"\(remotePath)\"")
                            self.onStateChange?(downloadID, .failed(reason: "\(peerUsername) didn't queue the file"))
                            self.finishSlot(for: peerUsername)
                        }
                        return
                    }
                    doReceive()
                }
            }
        }
        doReceive()
    }

    private func drainPeerBuffer(box: TransferBufferBox, conn: NWConnection, downloadID: UUID, peerUsername: String, remotePath: String, state: PConnectionState) {
        var buf = Data(box.data)
        box.data = Data()

        while buf.count >= 4 {
            let msgLength = Int(buf.readUInt32(at: 0))
            guard msgLength >= 4, msgLength <= 2_000_000 else { return }
            let totalNeeded = 4 + msgLength
            guard buf.count >= totalNeeded else { box.data = buf; return }
            guard buf.count >= 8 else { buf = Data(buf.dropFirst(totalNeeded)); continue }

            let code = buf.readUInt32(at: 4)
            let body = totalNeeded > 8 ? Data(buf[8..<totalNeeded]) : Data()
            buf = Data(buf.dropFirst(totalNeeded))

            DebugLog.shared.log("Download P-message from \(peerUsername) code:\(code) size:\(body.count)")
            if code == 40 {
                state.transferRequestHandled = true
                handleTransferRequest(body: body, conn: conn, downloadID: downloadID, peerUsername: peerUsername, remotePath: remotePath)
            }
        }
    }

    // MARK: - TransferRequest / TransferResponse (peer codes 40 / 41)

    private func handleTransferRequest(body: Data, conn: NWConnection, downloadID: UUID, peerUsername: String, remotePath: String) {
        var offset = 0
        guard offset + 4 <= body.count else { return }
        let direction = body.readUInt32(at: offset); offset += 4
        guard offset + 4 <= body.count else { return }
        let ticket = body.readUInt32(at: offset); offset += 4
        guard body.readSlskString(at: &offset) != nil else { return }

        var fileSize: UInt64 = 0
        if direction == 1, offset + 8 <= body.count {
            let lo = UInt64(body.readUInt32(at: offset)); offset += 4
            let hi = UInt64(body.readUInt32(at: offset))
            fileSize = lo | (hi << 32)
        }

        let session = Session(downloadID: downloadID, username: peerUsername, remotePath: remotePath, fileSize: fileSize)
        pendingByTicket[ticket] = session

        DebugLog.shared.log("TransferRequest from \(peerUsername) ticket:\(ticket) size:\(fileSize)")

        // TransferResponse: allowed = true. The peer now opens a separate
        // 'F' connection to actually send the bytes, so this P connection's
        // job is done.
        var replyBody = Data()
        replyBody.appendUInt32(ticket)
        replyBody.append(1)
        conn.send(content: buildPeerMessage(code: 41, body: replyBody), completion: .idempotent)

        onStateChange?(downloadID, .downloading(progress: 0, speedBytesPerSec: 0))
        conn.cancel()
    }

    // MARK: - F connection: ticket, FileOffset, raw file bytes

    /// `connectionToken` is the token the server gave us in ConnectToPeer to dial this
    /// peer and complete PierceFireWall — it is *not* the same number as the transfer
    /// ticket from TransferRequest. The real ticket only exists as the first 4 raw bytes
    /// the peer sends once this connection is open, and observed traffic shows it's
    /// reliably a few counts off from the connection token (they're independent counters
    /// on the peer's side), so pendingByTicket must be looked up using that value, not
    /// connectionToken. Using connectionToken here was the bug that made every transfer
    /// get rejected as "unrecognized ticket" and sit stuck at 0%.
    private func beginReceivingFile(connectionToken: UInt32, conn: NWConnection) {
        let box = TransferBufferBox()
        var resolvedTicket: UInt32?

        func doReceive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }

                    if let data {
                        box.data.append(data)

                        if resolvedTicket == nil {
                            guard box.data.count >= 4 else {
                                if isComplete {
                                    DebugLog.shared.log("Incoming file connection (connToken:\(connectionToken)) closed before ticket arrived")
                                    conn.cancel()
                                    return
                                }
                                doReceive()
                                return
                            }

                            // First 4 bytes are the uploader's FileTransferInit ticket —
                            // this is the value that actually matches TransferRequest's
                            // ticket, so resolve the session using it, not connectionToken.
                            let ticket = box.data.readUInt32(at: 0)
                            box.data = box.data.dropFirst(4)

                            guard var session = self.pendingByTicket[ticket] else {
                                DebugLog.shared.log("Incoming file connection with unrecognized ticket:\(ticket) (connToken:\(connectionToken))")
                                conn.cancel()
                                return
                            }
                            resolvedTicket = ticket

                            let (folderURL, isScoped) = self.settings.resolveDownloadFolder()
                            var scopedFolder: URL?
                            if isScoped {
                                if folderURL.startAccessingSecurityScopedResource() {
                                    scopedFolder = folderURL
                                } else {
                                    DebugLog.shared.log("Could not access chosen download folder, falling back to app storage")
                                }
                            }
                            let destFolder = scopedFolder ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                            let destURL = destFolder.appendingPathComponent(self.lastPathComponent(of: session.remotePath))
                            guard FileManager.default.createFile(atPath: destURL.path, contents: nil),
                                  let handle = try? FileHandle(forWritingTo: destURL) else {
                                scopedFolder?.stopAccessingSecurityScopedResource()
                                self.onStateChange?(session.downloadID, .failed(reason: "Could not create local file"))
                                self.pendingByTicket.removeValue(forKey: ticket)
                                self.finishSlot(for: session.username)
                                conn.cancel()
                                return
                            }
                            session.fileHandle = handle
                            session.destinationURL = destURL
                            session.securityScopedFolderURL = scopedFolder
                            session.speedWindowStart = Date()
                            session.speedWindowStartBytes = 0
                            self.pendingByTicket[ticket] = session

                            DebugLog.shared.log("Matched incoming file connection to ticket:\(ticket) (connToken:\(connectionToken)) — writing to \(destURL.lastPathComponent)")

                            // FileOffset (uint64) — always 0, no resume support.
                            var offsetMsg = Data()
                            offsetMsg.appendUInt32(0)
                            offsetMsg.appendUInt32(0)
                            conn.send(content: offsetMsg, completion: .idempotent)
                        }

                        if let ticket = resolvedTicket, !box.data.isEmpty {
                            self.appendFileBytes(ticket: ticket, chunk: box.data, conn: conn)
                            box.data = Data()
                        }
                    }

                    if error != nil {
                        if let ticket = resolvedTicket {
                            self.finishFailed(ticket: ticket, reason: error?.localizedDescription ?? "Connection error")
                        }
                        return
                    }
                    if isComplete {
                        // Peer closed early. If we already have the full file this is the
                        // normal "we closed it ourselves" case and pendingByTicket[ticket]
                        // will already be gone.
                        if let ticket = resolvedTicket, self.pendingByTicket[ticket] != nil {
                            self.finishFailed(ticket: ticket, reason: "Connection closed before transfer completed")
                        }
                        return
                    }
                    doReceive()
                }
            }
        }
        doReceive()
    }

    private func appendFileBytes(ticket: UInt32, chunk: Data, conn: NWConnection) {
        guard var session = pendingByTicket[ticket] else { return }
        session.fileHandle?.write(chunk)
        session.bytesReceived += UInt64(chunk.count)

        // Recompute speed at most every 0.5s so the number is stable/readable
        // rather than swinging wildly with each network chunk.
        let elapsed = Date().timeIntervalSince(session.speedWindowStart)
        if elapsed >= 0.5 {
            let bytesThisWindow = session.bytesReceived - session.speedWindowStartBytes
            session.currentSpeed = Double(bytesThisWindow) / elapsed
            session.speedWindowStart = Date()
            session.speedWindowStartBytes = session.bytesReceived
        }
        pendingByTicket[ticket] = session

        let progress = session.fileSize > 0 ? Double(session.bytesReceived) / Double(session.fileSize) : 0
        onStateChange?(session.downloadID, .downloading(progress: min(progress, 1.0), speedBytesPerSec: session.currentSpeed))

        if session.fileSize > 0, session.bytesReceived >= session.fileSize {
            session.fileHandle?.closeFile()
            session.securityScopedFolderURL?.stopAccessingSecurityScopedResource()
            pendingByTicket.removeValue(forKey: ticket)
            conn.cancel() // we (the downloader) are responsible for closing — see protocol notes
            DebugLog.shared.log("Download complete: \(session.remotePath) (\(session.bytesReceived) bytes)")
            onStateChange?(session.downloadID, .completed)
            finishSlot(for: session.username)
        }
    }

    private func finishFailed(ticket: UInt32, reason: String) {
        guard let session = pendingByTicket[ticket] else { return }
        session.fileHandle?.closeFile()
        if let url = session.destinationURL {
            try? FileManager.default.removeItem(at: url)
        }
        session.securityScopedFolderURL?.stopAccessingSecurityScopedResource()
        pendingByTicket.removeValue(forKey: ticket)
        DebugLog.shared.log("Download failed: \(session.remotePath) — \(reason)")
        onStateChange?(session.downloadID, .failed(reason: reason))
        finishSlot(for: session.username)
    }

    /// Soulseek filenames use Windows-style backslash paths (e.g.
    /// `@@user\Music\Album\Track.mp3`) regardless of platform, so
    /// NSString.lastPathComponent (which expects "/") isn't reliable here.
    private func lastPathComponent(of remotePath: String) -> String {
        let normalized = remotePath.replacingOccurrences(of: "\\", with: "/")
        let name = (normalized as NSString).lastPathComponent
        return name.isEmpty ? "download" : name
    }
}

private class TransferBufferBox: @unchecked Sendable {
    var data = Data()
}

/// Tracks, for a single P connection, whether we've already handled its
/// TransferRequest — so if the connection closes before one ever arrives, we
/// know to report a failure and free the peer's concurrency slot instead of
/// silently doing nothing.
private final class PConnectionState: @unchecked Sendable {
    var transferRequestHandled = false
}