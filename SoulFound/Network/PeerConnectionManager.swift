import Foundation
import Network
import Compression

// MARK: - DebugLog
class DebugLog: @unchecked Sendable {
    static let shared = DebugLog()
    private let fileURL: URL
    let fileURLPublic: URL
    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("soulfound_debug.txt")
        fileURLPublic = fileURL
        try? "".write(to: fileURL, atomically: true, encoding: .utf8)
    }
    func log(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        if let data = line.data(using: .utf8),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        }
    }
}

// MARK: - PeerConnectionManager
@MainActor
class PeerConnectionManager {

    var onSearchResults: (([SearchResult], UInt32) -> Void)?
    let listenPort: Int = 0
    private var activeConnections: [UInt32: NWConnection] = [:]

    func startListening() {}

    func connectOut(toIP ip: UInt32, port: UInt16, token: UInt32, peerUsername: String) {
        let ipString = "\((ip >> 24) & 0xFF).\((ip >> 16) & 0xFF).\((ip >> 8) & 0xFF).\(ip & 0xFF)"
        guard port > 0 else { return }
        let host = NWEndpoint.Host(ipString)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }

        let conn = NWConnection(host: host, port: nwPort, using: .tcp)
        activeConnections[token] = conn
        DebugLog.shared.log("Dialing peer \(peerUsername) at \(ipString):\(port) token:\(token)")

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    DebugLog.shared.log("Connected to peer token:\(token)")
                    self.sendPierceFireWall(conn: conn, token: token)
                    self.receivePeer(conn: conn, token: token)
                case .failed(let err):
                    DebugLog.shared.log("Peer connection failed token:\(token) err:\(err)")
                    self.activeConnections.removeValue(forKey: token)
                case .cancelled:
                    self.activeConnections.removeValue(forKey: token)
                default:
                    break
                }
            }
        }

        conn.start(queue: .main)

        Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if self.activeConnections[token] != nil {
                conn.cancel()
                self.activeConnections.removeValue(forKey: token)
            }
        }
    }

    private func sendPierceFireWall(conn: NWConnection, token: UInt32) {
        var body = Data()
        body.append(0)              // code 0 = PierceFireWall
        body.appendUInt32(token)

        var msg = Data()
        msg.appendUInt32(UInt32(body.count))  // length prefix
        msg.append(body)

        conn.send(content: msg, completion: .idempotent)
    }

    private func receivePeer(conn: NWConnection, token: UInt32) {
        let box = BufferBox()

        func doReceive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
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

    private func processPeerBuffer(box: BufferBox, conn: NWConnection, token: UInt32) {
        var buf = Data(box.data)
        box.data = Data()

        while buf.count >= 4 {
            let b0 = UInt32(buf[0]); let b1 = UInt32(buf[1])
            let b2 = UInt32(buf[2]); let b3 = UInt32(buf[3])
            let msgLength = Int(b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))

            guard msgLength >= 4, msgLength <= 50_000_000 else {
                DebugLog.shared.log("Peer bad msgLength:\(msgLength) token:\(token)")
                return
            }
            let totalNeeded = 4 + msgLength
            guard buf.count >= totalNeeded else {
                box.data = buf
                return
            }

            let code: UInt32
            if buf.count >= 8 {
                let c0 = UInt32(buf[4]); let c1 = UInt32(buf[5])
                let c2 = UInt32(buf[6]); let c3 = UInt32(buf[7])
                code = c0 | (c1 << 8) | (c2 << 16) | (c3 << 24)
            } else {
                buf = Data(buf.dropFirst(totalNeeded))
                continue
            }

            let body = totalNeeded > 8 ? Data(buf[8..<totalNeeded]) : Data()
            buf = Data(buf.dropFirst(totalNeeded))

            DebugLog.shared.log("Peer msg code:\(code) size:\(body.count) token:\(token)")
            handlePeerMessage(code: code, body: body, token: token, conn: conn)
        }
    }

    private func handlePeerMessage(code: UInt32, body: Data, token: UInt32, conn: NWConnection) {
        switch code {
        case 9:
            handleSearchResult(body: body, token: token)
            conn.cancel()
            activeConnections.removeValue(forKey: token)
        default:
            DebugLog.shared.log("Peer UNHANDLED code:\(code) size:\(body.count) token:\(token)")
        }
    }

    private func handleSearchResult(body: Data, token: UInt32) {
        guard let decompressed = zlibDecompress(body) else {
            DebugLog.shared.log("handleSearchResult: zlib decompress of full body failed, token:\(token)")
            return
        }

        let preview = decompressed.prefix(30).map { String(format: "%02x", $0) }.joined(separator: " ")
        DebugLog.shared.log("Decompressed preview (token \(token)) size:\(decompressed.count): \(preview)")

        var offset = 0
        guard let senderUsername = decompressed.readSlskString(at: &offset) else {
            DebugLog.shared.log("handleSearchResult: failed to read username after decompress")
            return
        }
        guard offset + 4 <= decompressed.count else { return }
        let resultToken = decompressed.readUInt32(at: offset); offset += 4

        DebugLog.shared.log("Search result from \(senderUsername) resultToken:\(resultToken) myToken:\(token)")

        let results = parseFileList(data: decompressed, username: senderUsername, startOffset: offset)
        DebugLog.shared.log("Parsed \(results.count) files from \(senderUsername)")

        guard !results.isEmpty else { return }
        onSearchResults?(results, token)
    }

    private func zlibDecompress(_ data: Data) -> Data? {
    guard data.count > 6 else { return nil }
    // Strip 2-byte zlib header and 4-byte Adler32 checksum trailer,
    // decompress as raw deflate stream instead
    let raw = data.subdata(in: 2..<(data.count - 4))

    let destinationSize = 10_000_000
    var destination = Data(count: destinationSize)
    let result = raw.withUnsafeBytes { srcPtr -> Int in
        guard let src = srcPtr.baseAddress else { return 0 }
        return destination.withUnsafeMutableBytes { dstPtr -> Int in
            guard let dst = dstPtr.baseAddress else { return 0 }
            return compression_decode_buffer(
                dst.assumingMemoryBound(to: UInt8.self), destinationSize,
                src.assumingMemoryBound(to: UInt8.self), raw.count,
                nil, COMPRESSION_ZLIB
            )
        }
    }
    guard result > 0 else {
        DebugLog.shared.log("zlib decompress failed, input size: \(data.count)")
        return nil
    }
    return destination.prefix(result)
}

    private func parseFileList(data: Data, username: String, startOffset: Int) -> [SearchResult] {
        var offset = startOffset
        var results: [SearchResult] = []

        guard offset + 4 <= data.count else { return results }
        let fileCount = Int(data.readUInt32(at: offset)); offset += 4
        guard fileCount > 0, fileCount < 10_000 else { return results }

        for _ in 0..<fileCount {
            guard offset < data.count else { break }
            offset += 1

            guard let filename = data.readSlskString(at: &offset) else { break }
            guard offset + 8 <= data.count else { break }

            let lo = UInt64(data.readUInt32(at: offset)); offset += 4
            let hi = UInt64(data.readUInt32(at: offset)); offset += 4
            let fileSize = lo | (hi << 32)

            guard data.readSlskString(at: &offset) != nil else { break }
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

            results.append(SearchResult(
                username: username,
                filename: filename,
                size: Int64(fileSize),
                bitrate: bitrate > 0 ? Int(bitrate) : nil,
                duration: duration > 0 ? Int(duration) : nil,
                remotePath: filename
            ))
        }
        return results
    }
}

private class BufferBox: @unchecked Sendable {
    var data = Data()
}

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
        append(UInt8((le >> 0) & 0xFF))
        append(UInt8((le >> 8) & 0xFF))
        append(UInt8((le >> 16) & 0xFF))
        append(UInt8((le >> 24) & 0xFF))
    }

    mutating func appendSlskString(_ string: String) {
        let bytes = string.data(using: .utf8) ?? Data()
        appendUInt32(UInt32(bytes.count))
        append(bytes)
    }
}