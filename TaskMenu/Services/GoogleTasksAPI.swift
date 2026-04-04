import Foundation

enum APIError: Error, Sendable {
    case unauthorized
    case networkError(URLError)
    case serverError(Int, String?)
    case decodingError(Error)
}

actor GoogleTasksAPI: TasksAPIProtocol {
    private let authService: GoogleAuthService
    private let session: URLSession
    private let baseURL: String

    init(authService: GoogleAuthService, session: URLSession = .shared, baseURL: String = Constants.googleTasksBaseURL) {
        self.authService = authService
        self.session = session
        self.baseURL = baseURL
    }

    // MARK: - Task Lists

    func listTaskLists() async throws -> [TaskList] {
        let data = try await request(path: "/users/@me/lists")
        let response = try decode(TaskListCollection.self, from: data)
        return response.items ?? []
    }

    // MARK: - Tasks

    func listTasks(listId: String, showCompleted: Bool = true, showHidden: Bool = true) async throws -> [TaskItem] {
        var allItems: [TaskItem] = []
        var pageToken: String?

        repeat {
            var queryItems = [URLQueryItem]()
            queryItems.append(URLQueryItem(name: "showCompleted", value: String(showCompleted)))
            queryItems.append(URLQueryItem(name: "showHidden", value: String(showHidden)))
            queryItems.append(URLQueryItem(name: "maxResults", value: "100"))
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }

            let data = try await request(path: "/lists/\(listId)/tasks", queryItems: queryItems)
            let response = try decode(TaskItemList.self, from: data)
            allItems.append(contentsOf: response.items ?? [])
            pageToken = response.nextPageToken
        } while pageToken != nil

        return allItems
    }

    func createTask(listId: String, title: String, notes: String? = nil, due: String? = nil, parentId: String? = nil) async throws -> TaskItem {
        var body: [String: Any] = ["title": title]
        if let notes { body["notes"] = notes }
        if let due { body["due"] = due }

        var queryItems = [URLQueryItem]()
        if let parentId { queryItems.append(URLQueryItem(name: "parent", value: parentId)) }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let data = try await request(path: "/lists/\(listId)/tasks", method: "POST", queryItems: queryItems, body: bodyData)
        return try decode(TaskItem.self, from: data)
    }

    func updateTask(listId: String, taskId: String, task: TaskItem) async throws -> TaskItem {
        let body = try makeTaskUpdateBody(for: task)
        let data = try await request(path: "/lists/\(listId)/tasks/\(taskId)", method: "PATCH", body: body)
        return try decode(TaskItem.self, from: data)
    }

    func deleteTask(listId: String, taskId: String) async throws {
        _ = try await request(path: "/lists/\(listId)/tasks/\(taskId)", method: "DELETE")
    }

    func moveTask(listId: String, taskId: String, previousId: String? = nil, parentId: String? = nil) async throws -> TaskItem {
        var queryItems = [URLQueryItem]()
        if let previousId { queryItems.append(URLQueryItem(name: "previous", value: previousId)) }
        if let parentId { queryItems.append(URLQueryItem(name: "parent", value: parentId)) }

        let data = try await request(path: "/lists/\(listId)/tasks/\(taskId)/move", method: "POST", queryItems: queryItems)
        return try decode(TaskItem.self, from: data)
    }

    // MARK: - Private

    private func request(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> Data {
        let token = try await authService.validAccessToken()

        var components = URLComponents(string: baseURL + path)!
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw APIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError(URLError(.badServerResponse))
        }

        switch httpResponse.statusCode {
        case 200...299:
            return data
        case 401:
            throw APIError.unauthorized
        default:
            let message = String(data: data, encoding: .utf8)
            throw APIError.serverError(httpResponse.statusCode, message)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    private func makeTaskUpdateBody(for task: TaskItem) throws -> Data {
        let body: [String: Any] = [
            "title": task.title,
            "status": task.status.rawValue,
            "notes": task.notes ?? NSNull(),
            "due": task.due ?? NSNull(),
        ]

        return try JSONSerialization.data(withJSONObject: body)
    }
}
