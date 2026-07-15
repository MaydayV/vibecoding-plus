import Foundation

struct TickTickProject: Codable, Sendable {
    let id: String
    let name: String
}

struct TickTickTask: Codable, Sendable {
    var id: String?
    var projectId: String
    var title: String
    var content: String?
    var desc: String?
    var status: Int
    var priority: Int?
    var isAllDay: Bool?
    var startDate: String?
    var dueDate: String?
    var timeZone: String?
    var completedTime: String?
}

enum TickTickError: Error, CustomStringConvertible {
    case invalidURL
    case missingToken
    case httpError(Int, String)
    case decodeError(Error)
    case unexpected(String)

    var description: String {
        switch self {
        case .invalidURL:
            return "Invalid TickTick API URL"
        case .missingToken:
            return "Missing TickTick access token"
        case .httpError(let code, let body):
            return "TickTick HTTP \(code): \(body.prefix(200))"
        case .decodeError(let error):
            return "TickTick decode error: \(error.localizedDescription)"
        case .unexpected(let message):
            return "TickTick error: \(message)"
        }
    }
}

actor TickTickAPIClient {
    private let baseURL = URL(string: "https://api.ticktick.com/open/v1")!
    private let urlSession: URLSession
    private var accessToken: String = ""

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func updateToken(_ token: String) {
        self.accessToken = token
    }

    private func request(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard !accessToken.isEmpty else { throw TickTickError.missingToken }
        guard let url = URL(string: path, relativeTo: baseURL) else { throw TickTickError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TickTickError.unexpected("Non-HTTP response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            throw TickTickError.httpError(httpResponse.statusCode, bodyString)
        }

        return data
    }

    func fetchProjects() async throws -> [TickTickProject] {
        let data = try await request(path: "/project")
        return try JSONDecoder().decode([TickTickProject].self, from: data)
    }

    func fetchTasks(projectId: String, status: Int? = nil) async throws -> [TickTickTask] {
        var path = "/project/\(projectId)/task"
        if let status = status {
            path += "?status=\(status)"
        }
        let data = try await request(path: path)
        return try JSONDecoder().decode([TickTickTask].self, from: data)
    }

    func createTask(_ task: TickTickTask) async throws -> TickTickTask {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(task)
        let data = try await request(path: "/task", method: "POST", body: body)
        return try JSONDecoder().decode(TickTickTask.self, from: data)
    }

    func updateTask(_ task: TickTickTask) async throws -> TickTickTask {
        guard let taskId = task.id, !taskId.isEmpty else {
            throw TickTickError.unexpected("Cannot update task without id")
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(task)
        let data = try await request(path: "/task/\(taskId)", method: "POST", body: body)
        return try JSONDecoder().decode(TickTickTask.self, from: data)
    }

    func deleteTask(taskId: String) async throws {
        _ = try await request(path: "/task/\(taskId)", method: "DELETE")
    }
}
