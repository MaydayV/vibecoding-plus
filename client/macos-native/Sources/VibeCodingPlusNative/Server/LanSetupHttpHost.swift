import Foundation
import Network

/// Thread-safe snapshot for the setup HTTP page (read from background queue).
final class SetupPageSnapshot {
    var hostId: String = "VibeServer"
    var hostName: String = ProcessInfo.processInfo.hostName
    var pairCode: String = "------"
    var hasSharedSecret: Bool = false

    func asInfo() -> LanSetupHttpHost.PairingPageInfo {
        LanSetupHttpHost.PairingPageInfo(
            hostId: hostId,
            hostName: hostName,
            pairCode: pairCode,
            hasSharedSecret: hasSharedSecret
        )
    }
}

/// Serves a mobile-friendly LAN setup / pairing page for NFC tap-to-open.
/// Used when the ESP32 is not yet connected — phone reads NFC → opens WiFi or Mac pairing help.
final class LanSetupHttpHost {
    static let defaultPort: UInt16 = 8768

    struct PairingPageInfo {
        var hostId: String
        var hostName: String
        var pairCode: String
        var hasSharedSecret: Bool
    }

    var infoProvider: (() -> PairingPageInfo)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "lan.setup.http")

    func start(port: UInt16 = LanSetupHttpHost.defaultPort) throws {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw URLError(.badURL)
        }
        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let path = self.requestPath(request)
            switch path {
            case "/", "/pair", "/setup":
                let info = self.infoProvider?() ?? PairingPageInfo(
                    hostId: "VibeServer",
                    hostName: ProcessInfo.processInfo.hostName,
                    pairCode: "------",
                    hasSharedSecret: false
                )
                let html = self.renderPairPage(info)
                self.sendResponse(connection, status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(html.utf8))
            default:
                self.sendResponse(connection, status: "404 Not Found", contentType: "text/plain", body: Data("not found".utf8))
            }
        }
    }

    private func requestPath(_ request: String) -> String {
        guard request.hasPrefix("GET ") else { return "" }
        let parts = request.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return "" }
        let target = String(parts[1])
        return target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
    }

    private func renderPairPage(_ info: PairingPageInfo) -> String {
        let secretNote = info.hasSharedSecret
            ? "Mac 客户端已启用 LAN 密钥。设备连上后，在「设备」页点「确认配对」下发密钥。"
            : "请先在 Mac 客户端设置中配置 LAN_SHARED_SECRET，再为设备确认配对。"
        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8"/>
          <meta name="viewport" content="width=device-width, initial-scale=1"/>
          <title>VibeCoding Plus 配对</title>
          <style>
            body { font-family: -apple-system, sans-serif; margin: 24px; line-height: 1.5; color: #1a1a1a; }
            h1 { font-size: 1.25rem; margin: 0 0 8px; }
            .code { font-size: 2rem; letter-spacing: 0.35em; font-weight: 700; margin: 12px 0; }
            .card { background: #f5f4ef; border-radius: 12px; padding: 16px; margin: 16px 0; }
            ol { padding-left: 1.2rem; }
            li { margin: 8px 0; }
          </style>
        </head>
        <body>
          <h1>墨水屏设备 · 连接此 Mac</h1>
          <p>Host ID：<strong>\(escapeHTML(info.hostId))</strong><br/>
             主机：<strong>\(escapeHTML(info.hostName))</strong></p>
          <div class="card">
            <div>配对码（供核对）</div>
            <div class="code">\(escapeHTML(info.pairCode))</div>
          </div>
          <div class="card">
            <strong>NFC 碰一碰是干什么的？</strong>
            <ol>
              <li><strong>还没连 Wi‑Fi</strong>：NFC 打开设备配网页，先配置 Wi‑Fi。</li>
              <li><strong>已有 Wi‑Fi、未连 Mac</strong>：NFC 打开本页；设备会自动发现 Mac，然后在 Mac 客户端「设备」里点「确认配对」。</li>
              <li><strong>已经连上 Mac</strong>：无需再碰 NFC 配对。</li>
            </ol>
            <p>\(escapeHTML(secretNote))</p>
          </div>
        </body>
        </html>
        """
    }

    private func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func sendResponse(_ connection: NWConnection, status: String, contentType: String, body: Data) {
        var headers = "HTTP/1.1 \(status)\r\n"
        headers += "Content-Type: \(contentType)\r\n"
        headers += "Content-Length: \(body.count)\r\n"
        headers += "Connection: close\r\n\r\n"
        var response = Data(headers.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
