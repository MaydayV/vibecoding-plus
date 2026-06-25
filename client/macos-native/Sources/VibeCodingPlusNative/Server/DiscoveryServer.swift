import Darwin
import Foundation

/// Listens for UDP discovery broadcasts from ESP32 devices on the LAN.
///
/// Mirrors the Node.js `discovery-server.mjs`: devices send a
/// `discover_host` JSON packet to the configured UDP port, and the server
/// replies with a `discover_reply` containing the WebSocket URL and an
/// optional HMAC signature.
actor DiscoveryServer {

    private let serviceTag = "vibecoding-plus"

    private var socketFD: Int32 = -1
    private var isRunning = false
    private var receiveSource: DispatchSourceRead?

    nonisolated(unsafe) var onLog: ((String) -> Void)?

    // MARK: - Lifecycle

    /// Starts listening for discovery requests on the configured UDP port.
    func start(config: ServerConfig) throws {
        guard config.discoveryEnabled else { return }
        guard !isRunning else { return }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var broadcast: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(config.discoveryPort).bigEndian
        addr.sin_addr.s_addr = inet_addr(config.bindHost)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
        }

        socketFD = fd
        isRunning = true

        let source = DispatchSource.makeReadSource(fileDescriptor: fd)
        source.setEventHandler { [weak self] in
            Task { await self?.handleIncomingData(fd: fd, config: config) }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        receiveSource = source
        onLog?("发现服务启动: udp://\(config.bindHost):\(config.discoveryPort)")
    }

    /// Stops listening and closes the UDP socket.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        receiveSource?.cancel()
        receiveSource = nil
        socketFD = -1
    }

    /// Sends a UDP broadcast to the discovery port, useful for triggering
    /// re-discovery from the host side.
    func sendBroadcast(config: ServerConfig) {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return }

        var broadcast: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))

        let payload = """
        {"type":"discover_host","service":"\(serviceTag)","deviceId":"macos-native","nonce":"\(UUID().uuidString)"}
        """

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(config.discoveryPort).bigEndian
        addr.sin_addr.s_addr = INADDR_BROADCAST

        payload.withCString { cstr in
            let len = strlen(cstr)
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(sock, cstr, len, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        close(sock)
    }

    // MARK: - Private

    private func handleIncomingData(fd: Int32, config: ServerConfig) {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var senderAddr = sockaddr_in()
        var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let bytesRead = withUnsafeMutablePointer(to: &senderAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(fd, &buffer, buffer.count, 0, $0, &senderLen)
            }
        }
        guard bytesRead > 0 else { return }

        let data = Data(buffer.prefix(bytesRead))
        guard let request = parseDiscoveryRequest(data) else { return }

        // Optional: filter by expected host id
        let expectedHostId = (request["expectedHostId"] as? String) ?? ""
        if !expectedHostId.isEmpty && expectedHostId != config.discoveryHostId {
            return
        }

        let remoteIP = String(cString: inet_ntoa(senderAddr.sin_addr))
        guard let replyAddress = findLocalAddress(forRemoteIP: remoteIP) else { return }

        let nonce = (request["nonce"] as? String) ?? ""
        let deviceId = (request["deviceId"] as? String) ?? "unknown"

        let replyHostName = "\(hostname) · \(replyAddress)"
        var body: [String: Any] = [
            "type": "discover_reply",
            "service": serviceTag,
            "hostId": config.discoveryHostId,
            "hostName": replyHostName,
            "wsUrl": "ws://\(replyAddress):\(config.port)",
            "wsPort": config.port,
            "nonce": nonce,
            "deviceId": deviceId,
        ]

        if !config.lanSharedSecret.isEmpty && !nonce.isEmpty {
            body["authSig"] = LANAuth.signDiscoveryReply(
                secret: config.lanSharedSecret,
                hostId: config.discoveryHostId,
                hostName: replyHostName,
                wsUrl: "ws://\(replyAddress):\(config.port)",
                nonce: nonce
            )
        }

        guard let replyData = try? JSONSerialization.data(withJSONObject: body),
              let replyString = String(data: replyData, encoding: .utf8) else { return }

        replyString.withCString { cstr in
            let len = strlen(cstr)
            withUnsafePointer(to: &senderAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(fd, cstr, len, 0, $0, senderLen)
                }
            }
        }
        onLog?("发现回复: remote=\(remoteIP), deviceId=\(deviceId)")
    }

    private func parseDiscoveryRequest(_ data: Data) -> [String: Any]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "discover_host" else {
            return nil
        }
        if let service = obj["service"] as? String, service != serviceTag {
            return nil
        }
        return obj
    }

    // MARK: - Network Helpers

    /// Returns the machine's hostname (matches `os.hostname()` in Node.js).
    private var hostname: String {
        ProcessInfo.processInfo.hostName
    }

    /// Finds the local IPv4 address that shares a subnet with `remoteIP`.
    ///
    /// Walks all network interfaces via `getifaddrs` and returns the first
    /// whose network portion (IP AND netmask) matches the remote address.
    /// Falls back to the first non-loopback IPv4 interface.
    private func findLocalAddress(forRemoteIP remoteIP: String) -> String? {
        guard let remoteParts = parseIPv4(remoteIP) else { return nil }

        var fallback: String?
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let iface = cursor?.pointee {
            cursor = iface.ifa_next

            guard let addrPtr = iface.ifa_addr, addrPtr.pointee.sa_family == sa_family_t(AF_INET) else {
                continue
            }
            guard let maskPtr = iface.ifa_netmask else { continue }

            let addr = addrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let mask = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }

            // Skip loopback
            if (Int32(iface.ifa_flags) & IFF_LOOPBACK) != 0 { continue }

            let localIP = String(cString: inet_ntoa(addr.sin_addr))
            guard let localParts = parseIPv4(localIP),
                  let maskParts = parseIPv4(String(cString: inet_ntoa(mask.sin_addr))) else {
                continue
            }

            if fallback == nil { fallback = localIP }

            let matchesSubnet = (0..<4).allSatisfy { i in
                (localParts[i] & maskParts[i]) == (remoteParts[i] & maskParts[i])
            }
            if matchesSubnet { return localIP }
        }

        return fallback
    }

    /// Parses an IPv4 dotted-decimal string into four octets.
    private func parseIPv4(_ address: String) -> [UInt32]? {
        let parts = address.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return nil }
        return parts
    }
}
