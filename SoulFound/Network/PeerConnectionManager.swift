import Foundation
import Network
import Compression

// MARK: - PeerConnectionManager
/// Handles outbound peer connections for receiving search results.
/// When the server sends us a ConnectToPeer (code 18), we dial out to the peer,
/// send PierceFireWall to identify ourselves, then wait for their FileSearchResult.
@MainActor
class PeerConnectionManager {

    /// Called on the main actor when results arrive. (token, results)
    var onSearchResults: (([SearchResult], UInt32) -> Void)?

    /// The port we advertise to the server via SetWaitPort.
    /// We use 0 here since we're not actually listening for inbound connections —
    /// all our peer connections are outbound (triggered by ConnectToPeer from the server).
    let listenPort: Int = 0

    // Active outbound peer connections, keyed by token
    private var activeConnections: [UInt32: NWConnection] = [:]

    // MARK: - Listening (no-op for download-only client)

    func startListening() {
        // We don't open an inbound listener. The server will send us ConnectToPeer
        // messages which we handle by dialing out to the peer ourselves.
    }

    // MARK: - Outbound connection to peer

    func connectOut(toIP ip: UInt32, port: UInt16, token: UInt32, peerUsername: String) {
        // Convert uint32 IP (little-endian from Soulseek) to dotted-decimal
        let ipString = "\(ip & 0xFF).\((ip >> 8) & 0xFF).\((ip >> 16) & 0xFF).\((ip >> 24) & 0xFF)"

        guard port > 0 else { return }

        let host = NWEndpoint.Host(ipString)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }

        let conn = NWConnection(host: host, port: nwPort, using: .tcp)
        activeConnections[token] = conn

        var receiveBuffer = Data()

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    // Send PierceFireWall (peer code 0) with the token
                    self.sendPierceFireWall(conn: conn, token: token)
                    self.receivePeer(conn: conn, buffer: &receiveBuffer, token: token)
                case .failed, .cancelled:
                    self.activeConnections.removeValue(forKey: token)
                default:
                    break
                }
            }
        }

        conn.start(queue: .main)

        // Time out after 15 seconds
        Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if self.activeConnections[token] != nil {
                conn.cancel()
                self.activeConnections.removeValue(forKey: token)
            }
        }
    }

    // MARK: - PierceFireWall (peer init code 0)

    private func sendPierceFireWall(conn: NWConnection, token: UInt32) {
        var body = Data()
        body.appendUInt32(token)

        var msg = Data()
        msg.appendUInt32(UInt32(1 + 4)) // length: 1 byte code + 4 byte token
        msg.append(0)                   // peer init code 0 = PierceFireWall
        msg.append(body)

        conn.send(content: msg, completion: .idempotent)
    }

    // MARK: - Peer receive loop

    private func receivePeer(conn: NWConnection, buffer: inout Data, token: UInt32) {
        // Swift inout + async closure capture requires a workaround — use a class box
        let box = BufferBox()

        func doReceive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let data {
                        box.data.append(data)
                        self.processPeerBuffer(box: box, conn: conn, token: token)
                    }
                    if error != nil || isComplete {
                        conn.cancel()
                        self.activeConnections.removeValue(forKey: token)
                        return
                    }
                    doReceive()
                }
            }
        }

        doReceive()
    }

    // MARK: - Peer message parsing

    private func processPeerBuffer(box: BufferBox, conn: NWConnection, token: UInt32) {
        while box.data.count >= 4 {
            let msgLength = Int(box.data.readUInt32(at: 0))
            guard msgLength >= 4, msgLength <= 50_000_000 else {
                box.data.removeAll()
                return
            }
            let totalNeeded = 4 + msgLength
            guard box.data.count >= totalNeeded else { break }

            let code = box.data.readUInt32(at: 4)
            let body = totalNeeded > 8 ? Data(box.data[8..<totalNeeded]) : Data()
            box.data.removeFirst(totalNeeded)

            handlePeerMessage(code: code, body: body, token: token, conn: conn)
        }
    }

    private func handlePeerMessage(code: UInt32, body: Data, token: UInt32, conn: NWConnection) {
        switch code {
        case 9:
            // FileSearchResult
            handleSearchResult(body: body, token: token)
            conn.cancel()
            activeConnections.removeValue(forKey: token)
        default:
            break
        }
    }

    // MARK: - FileSearchResult (peer code 9)

    private func handleSearchResult(body: Data, token: UInt32) {
        // Body layout:
        //   string  username
        //   uint32  token
        //   [rest]  zlib-compressed payload
        var offset = 0
        guard let senderUsername = body.readSlskString(at: &offset) else { return }
        guard offset + 4 <= body.count else { return }
        let resultToken = body.readUInt32(at: offset); offset += 4

        _ = senderUsername // used for attribution later

        // The rest is zlib-compressed. Soulseek uses raw deflate wrapped in a
        // zlib header (2 bytes) and checksum (4 bytes). We strip both ends.
        guard offset + 6 <= body.count else { return }
        let compressed = body.subdata(in: (offset + 2)..<(body.count - 4))
        guard let decompressed = zlibDecompress(compressed) else { return }

        let results = parseFileList(data: decompressed, username: senderUsername)
        guard !results.isEmpty else { return }

        onSearchResults?(results, resultToken)
    }

    // MARK: - zlib decompression (raw deflate)

    private func zlibDecompress(_ data: Data) -> Data? {
        // We need raw deflate (no zlib header). Apple's Compression framework
        // provides COMPRESSION_ZLIB which handles raw deflate directly.
        let destinationSize = 10_000_000 // 10 MB cap
        var destination = Data(count: destinationSize)

        let result = data.withUnsafeBytes { srcPtr -> Int in
            guard let src = srcPtr.baseAddress else { return 0 }
            return destination.withUnsafeMutableBytes { dstPtr -> Int in
                guard let dst = dstPtr.baseAddress else { return 0 }
                return compression_decode_buffer(
                    dst.assumingMemoryBound(to: UInt8.self), destinationSize,
                    src.assumingMemoryBound(to: UInt8.self), data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard result > 0 else { return nil }
        return destination.prefix(result)
    }

    // MARK: - File list parser

    private func parseFileList(data: Data, username: String) -> [SearchResult] {
        var offset = 0
        var results: [SearchResult] = []

        guard offset + 4 <= data.count else { return results }
        let fileCount = Int(data.readUInt32(at: offset)); offset += 4

        guard fileCount > 0, fileCount < 10_000 else { return results }

        for _ in 0..<fileCount {
            // Each file entry:
            //   uint8   code (1 = file)
            //   string  filename (full path, backslash-separated)
            //   uint64  file size
            //   string  extension
            //   uint32  attribute count
            //   [attributes: uint32 type, uint32 value] * count

            guard offset < data.count else { break }
            offset += 1 // skip code byte

            guard let filename = data.readSlskString(at: &offset) else { break }
            guard offset + 8 <= data.count else { break }

            // File size is uint64
            let lo = UInt64(data.readUInt32(at: offset)); offset += 4
            let hi = UInt64(data.readUInt32(at: offset)); offset += 4
            let fileSize = lo | (hi << 32)

            guard let ext = data.readSlskString(at: &offset) else { break }
            guard offset + 4 <= data.count else { break }
            let attrCount = Int(data.readUInt32(at: offset)); offset += 4

            var bitrate: UInt32 = 0
            var duration: UInt32 = 0

            for _ in 0..<attrCount {
                guard offset + 8 <= data.count else { break }
                let attrType = data.readUInt32(at: offset); offset += 4
                let attrValue = data.readUInt32(at: offset); offset += 4
                switch attrType {
                case 0: bitrate = attrValue
                case 1: duration = attrValue
                default: break
                }
            }

            _ = ext // available for display later

            let result = SearchResult(
                username: username,
                filename: filename,
                size: Int64(fileSize),
                bitrate: bitrate > 0 ? Int(bitrate) : nil,
                duration: duration > 0 ? Int(duration) : nil,
                remotePath: filename
            )
        }

        return results
    }
}

// MARK: - BufferBox
// Simple reference-type wrapper so we can mutate a buffer inside async closures
private class BufferBox: @unchecked Sendable {
    var data = Data()
}

// MARK: - Data extensions (shared helpers)

extension Data {
    func readUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let b0 = UInt32(self[index(startIndex, offsetBy: offset)])
        let b1 = UInt32(self[index(startIndex, offsetBy: offset + 1)])
        let b2 = UInt32(self[index(startIndex, offsetBy: offset + 2)])
        let b3 = UInt32(self[index(startIndex, offsetBy: offset + 3)])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    func readSlskString(at offset: inout Int) -> String? {
        guard offset + 4 <= count else { return nil }
        let length = Int(readUInt32(at: offset)); offset += 4
        guard length >= 0, offset + length <= count else { return nil }
        let strData = subdata(in: offset..<(offset + length)); offset += length
        return String(data: strData, encoding: .utf8) ?? String(data: strData, encoding: .isoLatin1)
    }

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
}
