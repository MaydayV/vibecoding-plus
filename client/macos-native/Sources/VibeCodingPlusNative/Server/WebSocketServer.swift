import Foundation
import Network
import CryptoKit

// MARK: - WSMessage

enum WSMessage {
    case text(String)
    case binary(Data)
}

// MARK: - WSFrameMessage (internal)

enum WSFrameMessage {
    case text(String)
    case binary(Data)
    case ping
    case close
}

// MARK: - WSOpcode

enum WSOpcode: UInt8 {
    case text   = 0x01
    case binary = 0x02
    case close  = 0x08
    case ping   = 0x09
    case pong   = 0x0A
}

// MARK: - WSEncoder

enum WSEncoder {
    static func encode(opcode: WSOpcode, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | opcode.rawValue)

        let len = payload.count
        if len < 126 {
            frame.append(UInt8(len))
        } else if len <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(127)
            for i in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((len >> i) & 0xFF))
            }
        }

        frame.append(payload)
        return frame
    }
}

// MARK: - WSFrameParser

final class WSFrameParser {
    private var buffer: [UInt8] = []

    func feed(_ data: Data) -> [WSFrameMessage] {
        buffer.append(contentsOf: data)
        var messages: [WSFrameMessage] = []
        while !buffer.isEmpty {
            guard let result = parseOne() else { break }
            messages.append(result)
        }
        return messages
    }

    private func parseOne() -> WSFrameMessage? {
        guard buffer.count >= 2 else { return nil }

        let byte0 = buffer[0]
        let byte1 = buffer[1]
        let opcode = byte0 & 0x0F
        let masked = (byte1 & 0x80) != 0
        var payloadLen = Int(byte1 & 0x7F)
        var offset = 2

        if payloadLen == 126 {
            guard buffer.count >= offset + 2 else { return nil }
            payloadLen = Int(UInt16(buffer[offset]) << 8 | UInt16(buffer[offset + 1]))
            offset += 2
        } else if payloadLen == 127 {
            guard buffer.count >= offset + 8 else { return nil }
            var val: UInt64 = 0
            for i in 0..<8 { val = (val << 8) | UInt64(buffer[offset + i]) }
            guard val <= Int.max else { return nil }
            payloadLen = Int(val)
            offset += 8
        }

        var maskKey: [UInt8]?
        if masked {
            guard buffer.count >= offset + 4 else { return nil }
            maskKey = Array(buffer[offset..<offset + 4])
            offset += 4
        }

        guard buffer.count >= offset + payloadLen else { return nil }

        var payloadBytes = Array(buffer[offset..<offset + payloadLen])
        buffer.removeFirst(offset + payloadLen)

        if let maskKey {
            for i in payloadBytes.indices {
                payloadBytes[i] ^= maskKey[i % 4]
            }
        }
        let payload = Data(payloadBytes)

        switch opcode {
        case 0x01:
            guard (byte0 & 0x80) != 0 else { return nil }
            guard let str = String(data: payload, encoding: .utf8) else { return nil }
            return .text(str)
        case 0x02:
            guard (byte0 & 0x80) != 0 else { return nil }
            return .binary(payload)
        case 0x09: return .ping
        case 0x08: return .close
        default:   return nil
        }
    }
}

// MARK: - WSConnection

/// A single WebSocket connection. Thread-safe for send/close/metadata access.
final class WSConnection: Identifiable, @unchecked Sendable {
    let id: UUID
    let remoteAddress: String
    private let connection: NWConnection
    private let frameParser = WSFrameParser()
    private let writeQueue: DispatchQueue
    private let lock = NSLock()
    private var _isOpen = true
    private var _metadata: [String: Any] = [:]

    var onMessage: (@Sendable (WSMessage) -> Void)?
    var onDisconnect: (@Sendable () -> Void)?

    var metadata: [String: Any] {
        get { lock.lock(); defer { lock.unlock() }; return _metadata }
        set { lock.lock(); _metadata = newValue; lock.unlock() }
    }

    private var isOpen: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isOpen }
        set { lock.lock(); _isOpen = newValue; lock.unlock() }
    }

    init(connection: NWConnection) {
        self.id = UUID()
        self.remoteAddress = Self.extractRemoteAddress(connection)
        self.connection = connection
        self.writeQueue = DispatchQueue(label: "ws.write.\(id)")
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.handleDisconnect()
            default: break
            }
        }
        receiveLoop()
        connection.start(queue: DispatchQueue(label: "ws.conn.\(id)"))
    }

    func send(text: String) {
        guard isOpen, let data = text.data(using: .utf8) else { return }
        sendRaw(WSEncoder.encode(opcode: .text, payload: data))
    }

    func send(binary: Data) {
        guard isOpen else { return }
        sendRaw(WSEncoder.encode(opcode: .binary, payload: binary))
    }

    func sendPing() {
        guard isOpen else { return }
        sendRaw(WSEncoder.encode(opcode: .ping, payload: Data()))
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        sendRaw(WSEncoder.encode(opcode: .close, payload: Data()))
        connection.cancel()
    }

    func processLeftover(_ data: Data) {
        for msg in frameParser.feed(data) { handleFrameMessage(msg) }
    }

    private static func extractRemoteAddress(_ conn: NWConnection) -> String {
        if case .hostPort(let host, let port) = conn.endpoint {
            return "\(host):\(port)"
        }
        return "unknown"
    }

    private func sendRaw(_ data: Data) {
        writeQueue.async { [weak self] in
            self?.connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                for msg in self.frameParser.feed(data) { self.handleFrameMessage(msg) }
            }
            if isComplete || error != nil {
                self.handleDisconnect()
                return
            }
            if self.isOpen { self.receiveLoop() }
        }
    }

    private func handleFrameMessage(_ msg: WSFrameMessage) {
        switch msg {
        case .text(let str):  onMessage?(.text(str))
        case .binary(let d):  onMessage?(.binary(d))
        case .ping:           sendRaw(WSEncoder.encode(opcode: .pong, payload: Data()))
        case .close:          close()
        }
    }

    private func handleDisconnect() {
        guard isOpen else { return }
        isOpen = false
        onDisconnect?()
    }
}

// MARK: - WebSocketServer

/// Actor-isolated WebSocket server.
///
/// All mutable state (`connections`) is protected by actor isolation.
/// TCP handling and the HTTP upgrade handshake run on `listenerQueue`
/// (outside the actor); once upgraded, connections are registered via
/// the actor-isolated `finishUpgrade`.
actor WebSocketServer {
    private(set) var connections: [UUID: WSConnection] = [:]
    private var listener: NWListener?
    private let listenerQueue = DispatchQueue(label: "ws.listener")

    nonisolated(unsafe) var onConnection: ((WSConnection) -> Void)?
    nonisolated(unsafe) var onDisconnect: ((WSConnection) -> Void)?

    // MARK: Lifecycle

    func start(port: UInt16) throws {
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let listener = try NWListener(using: .tcp, on: nwPort)

        listener.newConnectionHandler = { [weak self] nwConn in
            guard let self else { return }
            self.handleTCPConnection(nwConn)
        }

        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("[WebSocketServer] Listener failed: \(error)")
            }
        }

        listener.start(queue: listenerQueue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        let conns = Array(connections.values)
        connections.removeAll()
        for conn in conns { conn.close() }
    }

    // MARK: Broadcasting

    func broadcast(text: String) {
        for conn in connections.values { conn.send(text: text) }
    }

    func broadcast(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let str = String(data: data, encoding: .utf8) else { return }
        broadcast(text: str)
    }

    func connectionCount() -> Int { connections.count }

    func connection(id: UUID) -> WSConnection? { connections[id] }

    func allConnections() -> [WSConnection] { Array(connections.values) }

    func broadcastAuthenticated(json: [String: Any], excludeId: UUID? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let str = String(data: data, encoding: .utf8) else { return }
        for (id, conn) in connections {
            guard id != excludeId, conn.metadata["authenticated"] as? Bool == true else { continue }
            conn.send(text: str)
        }
    }

    // MARK: - TCP → WebSocket Upgrade (runs on listenerQueue)

    /// Nonisolated — runs entirely on `listenerQueue`. Reads the HTTP
    /// upgrade request, then calls actor-isolated `finishUpgrade` to
    /// register the connection.
    private nonisolated func handleTCPConnection(_ nwConn: NWConnection) {
        nwConn.start(queue: listenerQueue)
        var accumulated = Data()

        func readMore() {
            nwConn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
                guard let self else { return }

                if let data, !data.isEmpty { accumulated.append(data) }

                if isComplete || error != nil {
                    nwConn.cancel()
                    return
                }

                if let range = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = accumulated[..<range.lowerBound]
                    let leftover = Data(accumulated[range.upperBound...])

                    guard let request = String(data: headerData, encoding: .utf8) else {
                        nwConn.cancel()
                        return
                    }

                    // Perform the WS upgrade handshake on listenerQueue
                    self.performUpgrade(nwConn, request: request, leftover: leftover)
                } else {
                    readMore()
                }
            }
        }

        readMore()
    }

    /// Completes the WebSocket handshake (runs on listenerQueue).
    /// Registers the connection via the actor-isolated `finishUpgrade`.
    private nonisolated func performUpgrade(_ nwConn: NWConnection, request: String, leftover: Data) {
        guard let key = extractHeader(request, name: "Sec-WebSocket-Key") else {
            nwConn.cancel()
            return
        }

        let accept = computeAcceptKey(key)
        let response =
            "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Accept: \(accept)\r\n" +
            "\r\n"

        nwConn.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                nwConn.cancel()
                return
            }

            let wsConn = WSConnection(connection: nwConn)
            wsConn.onDisconnect = { [weak self] in
                guard let self else { return }
                Task { await self.removeConnection(wsConn) }
            }

            // Feed leftover BEFORE starting receiveLoop to avoid data race
            if !leftover.isEmpty {
                wsConn.processLeftover(leftover)
            }

            wsConn.start()

            // Register via actor-isolated method (safe hop)
            Task { await self.finishUpgrade(wsConn) }
        })
    }

    /// Actor-isolated: registers a newly upgraded connection.
    private func finishUpgrade(_ conn: WSConnection) {
        connections[conn.id] = conn
        onConnection?(conn)
    }

    private func removeConnection(_ conn: WSConnection) {
        connections.removeValue(forKey: conn.id)
        onDisconnect?(conn)
    }

    // MARK: HTTP Header Helpers

    private nonisolated func extractHeader(_ request: String, name: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?i)^\(escaped)\\s*:\\s*(.+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return nil }
        let range = NSRange(request.startIndex..., in: request)
        guard let match = regex.firstMatch(in: request, range: range),
              let valueRange = Range(match.range(at: 1), in: request) else { return nil }
        return String(request[valueRange]).trimmingCharacters(in: .whitespaces)
    }

    private nonisolated func computeAcceptKey(_ key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-5AB5DC525AA5"
        let hash = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        return Data(hash).base64EncodedString()
    }
}
