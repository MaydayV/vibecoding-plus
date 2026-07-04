import CryptoKit
import Foundation
import Network

/// Serves a firmware `.bin` over plain HTTP on the LAN for ESP32 OTA.
final class FirmwareOtaHost {
    private var listener: NWListener?
    private var fileData: Data?
    private(set) var sha256Hex: String = ""
    private(set) var fileSize: Int = 0
    private(set) var servedPath: URL?

    func start(binURL: URL, port: UInt16 = 8767) throws -> (sha256: String, size: Int) {
        stop()
        let data = try Data(contentsOf: binURL)
        let digest = SHA256.hash(data: data)
        sha256Hex = digest.map { String(format: "%02x", $0) }.joined()
        fileSize = data.count
        fileData = data
        servedPath = binURL

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw URLError(.badURL)
        }
        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
        return (sha256Hex, fileSize)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        fileData = nil
        servedPath = nil
        sha256Hex = ""
        fileSize = 0
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            guard request.hasPrefix("GET ") else {
                self.sendResponse(connection, status: "404 Not Found", body: Data("not found".utf8))
                return
            }
            guard let payload = self.fileData else {
                self.sendResponse(connection, status: "503 Service Unavailable", body: Data())
                return
            }
            var headers = "HTTP/1.1 200 OK\r\n"
            headers += "Content-Type: application/octet-stream\r\n"
            headers += "Content-Length: \(payload.count)\r\n"
            headers += "Connection: close\r\n\r\n"
            var response = Data(headers.utf8)
            response.append(payload)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func sendResponse(_ connection: NWConnection, status: String, body: Data) {
        var headers = "HTTP/1.1 \(status)\r\n"
        headers += "Content-Length: \(body.count)\r\n"
        headers += "Connection: close\r\n\r\n"
        var response = Data(headers.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
