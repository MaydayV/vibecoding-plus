import Foundation

struct AdminAPIClient {
    var port: Int

    private var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    func getDevices() async throws -> [DeviceInfo] {
        struct Payload: Decodable { var ok: Bool; var devices: [DeviceInfo] }
        let payload: Payload = try await get("/api/admin/devices")
        return payload.devices
    }

    func getServiceStatus() async throws -> ServiceStatusPayload {
        try await get("/api/admin/service-status")
    }

    func getTodos() async throws -> TodoSnapshot {
        struct Payload: Decodable { var ok: Bool; var snapshot: TodoSnapshot }
        let payload: Payload = try await get("/api/admin/todos")
        return payload.snapshot
    }

    func createTodo(title: String, dueAt: String? = nil) async throws {
        _ = try await request("/api/admin/todos", method: "POST", body: ["title": title, "dueAt": dueAt ?? ""])
    }

    func updateTodo(id: String, completed: Bool) async throws {
        _ = try await request("/api/admin/todos", method: "PUT", body: TodoUpdateRequest(id: id, completed: completed))
    }

    func deleteTodo(id: String) async throws {
        _ = try await request("/api/admin/todos", method: "DELETE", body: ["id": id])
    }

    func syncStatus() async throws -> ReminderSyncPayload {
        try await get("/api/admin/todo-sync")
    }

    func runSyncNow() async throws {
        _ = try await request("/api/admin/todo-sync/run", method: "POST", body: ["reason": "native_app"])
    }

    func discover() async throws {
        _ = try await request("/api/admin/discover", method: "POST", body: [:] as [String: String])
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let url = baseURL.appending(path: path)
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    private func request(_ path: String, method: String, body: some Encodable) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        return data
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
    }
}

private struct TodoUpdateRequest: Encodable {
    var id: String
    var completed: Bool
}

struct AnyEncodable: Encodable {
    private let encodeBody: (Encoder) throws -> Void

    init(_ value: some Encodable) {
        encodeBody = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeBody(encoder)
    }
}
