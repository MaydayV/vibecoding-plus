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

    /// Bumped on every `start()`/`stop()`. Captured by the read-source event
    /// handler and re-checked at the top of `handleIncomingData`, so a call
    /// that was queued before a `stop()` (or before a `stop()` + `start()`
    /// restart that happens to recycle the same fd number) can recognize
    /// it's stale and return without touching the fd. See the race note
    /// on `stop()`.
    private var generation: UInt64 = 0

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

        // Non-blocking mode is required for correctness, not just performance:
        // DispatchSourceRead is level-triggered, and the actual `recvfrom`
        // happens later on the actor (event handler only hops into a Task),
        // so a single incoming datagram can cause the source to fire more
        // than once before the first Task drains it. With a blocking socket,
        // every redundant Task would then block forever in `recvfrom` once
        // the one pending packet was already consumed — permanently wedging
        // this actor (nothing else on it, including `stop()`, can ever run
        // again) and leaking a Swift concurrency worker thread. Making the fd
        // non-blocking and draining in a loop below until EAGAIN turns those
        // redundant wakeups into a harmless no-op instead of a hang.
        let existingFlags = fcntl(fd, F_GETFL, 0)
        guard existingFlags != -1, fcntl(fd, F_SETFL, existingFlags | O_NONBLOCK) != -1 else {
            close(fd)
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
        generation += 1
        let startGeneration = generation

        let source = DispatchSource.makeReadSource(fileDescriptor: fd)
        source.setEventHandler { [weak self] in
            Task { await self?.handleIncomingData(fd: fd, generation: startGeneration, config: config) }
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
        generation += 1
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
        {"type":"\(LANDeviceMessage.discover_host)","service":"\(serviceTag)","deviceId":"macos-native","nonce":"\(UUID().uuidString)"}
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

    private func handleIncomingData(fd: Int32, generation callerGeneration: UInt64, config: ServerConfig) {
        // Stale-call guard: `stop()` (or `stop()` followed by a `start()`
        // restart) may have already run for this fd by the time this Task
        // actually gets scheduled on the actor. `fd == socketFD` catches the
        // plain-stop case (socketFD is reset to -1); `callerGeneration ==
        // generation` also catches the rarer restart case where the OS
        // happens to recycle the exact same fd number. Either way, bailing
        // out here means we never call `recvfrom`/`sendto` on a fd that may
        // already be closed (by `stop()`'s cancel handler) or reassigned to
        // an unrelated socket — no matter how the actor happens to interleave
        // this call relative to `stop()`.
        guard isRunning, fd == socketFD, callerGeneration == generation else { return }

        // `fd` is non-blocking (set in `start()`), so drain datagrams queued
        // on the socket right now: the level-triggered DispatchSourceRead can
        // otherwise fire again for data this same call already consumed,
        // spawning a redundant Task that would find nothing left to read.
        // Looping here until EAGAIN/EWOULDBLOCK (bounded below) means that
        // redundant Task's `recvfrom` returns immediately instead of
        // blocking — see the longer explanation in `start()`.
        //
        // The loop is capped at `maxDatagramsPerBatch` rather than running
        // until EAGAIN unconditionally. Per accepted datagram this does a
        // full `getifaddrs`/`freeifaddrs` interface walk (`findLocalAddress`),
        // a JSON encode, and up to two HMAC-SHA256 signatures — real CPU work
        // with no `await` in between, so an unbounded loop would let a UDP
        // broadcast storm (or a deliberate flood) occupy this actor
        // indefinitely, wedging it exactly like the original blocking-socket
        // bug did, just via packet volume instead of a blocked syscall —
        // and while wedged, `stop()` can never even be scheduled. 32 is
        // comfortably above any realistic LAN discovery burst (a handful of
        // ESP32 devices at most send `discover_host` at once) while keeping
        // worst-case per-invocation occupancy small. If more than 32
        // datagrams are queued, `DispatchSourceRead` simply fires again once
        // this call returns and a fresh Task drains the next batch — so
        // returning at the cap (instead of forcing this call to reach EAGAIN
        // no matter what) is what lets `stop()` and other actor-isolated work
        // interleave between batches under sustained volume.
        let maxDatagramsPerBatch = 32
        var buffer = [UInt8](repeating: 0, count: 2048)

        // `findLocalAddress` walks every network interface via `getifaddrs`;
        // the interface list won't meaningfully change over the lifetime of
        // one batch, so memoize it per remote IP for this call only (cache is
        // local to this invocation and discarded on return — no persisted
        // state, no change to what any individual packet gets as a reply).
        var localAddressCache: [String: String?] = [:]

        for _ in 0..<maxDatagramsPerBatch {
            var senderAddr = sockaddr_in()
            var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let bytesRead = withUnsafeMutablePointer(to: &senderAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &senderLen)
                }
            }

            if bytesRead < 0 {
                if errno == EINTR { continue } // interrupted syscall, retry
                // EAGAIN/EWOULDBLOCK: nothing left queued right now. Any
                // other error (e.g. EBADF if the fd was concurrently torn
                // down) also means there's nothing useful left to do here.
                return
            }
            guard bytesRead > 0 else { continue } // valid zero-length datagram; keep draining

            let data = Data(buffer.prefix(bytesRead))
            guard let request = parseDiscoveryRequest(data) else { continue }

            // Optional: filter by expected host id
            let expectedHostId = (request["expectedHostId"] as? String) ?? ""
            if !expectedHostId.isEmpty && expectedHostId != config.discoveryHostId {
                continue
            }

            let remoteIP = String(cString: inet_ntoa(senderAddr.sin_addr))
            let replyAddressLookup: String?
            if let cached = localAddressCache[remoteIP] {
                replyAddressLookup = cached
            } else {
                let resolved = findLocalAddress(forRemoteIP: remoteIP)
                localAddressCache.updateValue(resolved, forKey: remoteIP)
                replyAddressLookup = resolved
            }
            guard let replyAddress = replyAddressLookup else { continue }

            let nonce = (request["nonce"] as? String) ?? ""
            let deviceId = (request["deviceId"] as? String) ?? "unknown"

            let replyHostName = "\(hostname) · \(replyAddress)"
            let pairUrl = "http://\(replyAddress):\(config.setupPort)/pair"
            var body: [String: Any] = [
                "type": LANServerMessage.discover_reply,
                "service": serviceTag,
                "hostId": config.discoveryHostId,
                "hostName": replyHostName,
                "wsUrl": "ws://\(replyAddress):\(config.port)",
                "wsPort": config.port,
                "pairUrl": pairUrl,
                "nonce": nonce,
                "deviceId": deviceId,
            ]
            if !config.pairingCode.isEmpty {
                body["pairCode"] = config.pairingCode
            }
            if !config.lanSharedSecret.isEmpty, !nonce.isEmpty, !config.pairingCode.isEmpty {
                body["pairToken"] = LANAuth.signPairToken(
                    secret: config.lanSharedSecret,
                    hostId: config.discoveryHostId,
                    pairCode: config.pairingCode,
                    nonce: nonce
                )
            }

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
                  let replyString = String(data: replyData, encoding: .utf8) else { continue }

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
        // Cap reached with the socket possibly still non-empty: fall out and
        // return here (rather than looping back to check for EAGAIN) so this
        // actor turn ends. If datagrams remain queued, the level-triggered
        // source fires again and a fresh Task picks up the next batch — see
        // the cap comment above.
    }

    private func parseDiscoveryRequest(_ data: Data) -> [String: Any]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == LANDeviceMessage.discover_host else {
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

    func localAddress(forRemoteIP remoteIP: String) -> String? {
        findLocalAddress(forRemoteIP: remoteIP)
    }

    /// Parses an IPv4 dotted-decimal string into four octets.
    private func parseIPv4(_ address: String) -> [UInt32]? {
        let parts = address.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return nil }
        return parts
    }
}
