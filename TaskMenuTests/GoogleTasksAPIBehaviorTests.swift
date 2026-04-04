import XCTest
@testable import TaskMenu

/// Tests for GoogleTasksAPI behavior: pagination, parameter passing, error handling.
/// Uses MockURLProtocol to simulate HTTP responses.
/// Uses MockURLProtocol.requestLog to inspect requests (avoids captured var issues with Swift 6 concurrency).
@MainActor
final class GoogleTasksAPIBehaviorTests: XCTestCase {
    nonisolated(unsafe) private static var capturedRequestBody: Data?
    private var keychain: InMemoryKeychainService!
    private var api: GoogleTasksAPI!

    override func setUp() async throws {
        MockURLProtocol.reset()

        keychain = InMemoryKeychainService()
        // Pre-load valid tokens so validAccessToken() returns without refreshing
        try? keychain.save(key: Constants.Keychain.accessTokenKey, string: "test-token")
        try? keychain.save(key: Constants.Keychain.refreshTokenKey, string: "test-refresh")
        let futureExpiration = String(Date().addingTimeInterval(3600).timeIntervalSince1970)
        try? keychain.save(key: Constants.Keychain.expirationKey, string: futureExpiration)

        let session = MockURLProtocol.mockSession()
        let authService = GoogleAuthService(keychain: keychain, session: session)
        api = GoogleTasksAPI(authService: authService, session: session)
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        try? keychain.deleteAll()
    }

    // MARK: - Pagination

    func testListTasksSinglePage() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"items":[{"id":"t1","title":"Task 1","status":"needsAction"},{"id":"t2","title":"Task 2","status":"completed"}]}"#
            return (response, json.data(using: .utf8)!)
        }

        let tasks = try await api.listTasks(listId: "list1")

        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks[0].id, "t1")
        XCTAssertEqual(tasks[1].id, "t2")
    }

    func testListTasksMultiplePagesFollowsNextPageToken() async throws {
        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!

            if url.contains("pageToken=page2") {
                let json = #"{"items":[{"id":"t3","title":"Task 3","status":"needsAction"}]}"#
                return (response, json.data(using: .utf8)!)
            } else {
                let json = #"{"items":[{"id":"t1","title":"Task 1","status":"needsAction"},{"id":"t2","title":"Task 2","status":"needsAction"}],"nextPageToken":"page2"}"#
                return (response, json.data(using: .utf8)!)
            }
        }

        let tasks = try await api.listTasks(listId: "list1")

        XCTAssertEqual(tasks.count, 3)
        XCTAssertEqual(tasks[0].id, "t1")
        XCTAssertEqual(tasks[1].id, "t2")
        XCTAssertEqual(tasks[2].id, "t3")
        // Verify two requests were made (page 1 + page 2)
        XCTAssertEqual(MockURLProtocol.requestLog.count, 2)
    }

    func testListTasksEmptyResponse() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, #"{"kind":"tasks#tasks"}"#.data(using: .utf8)!)
        }

        let tasks = try await api.listTasks(listId: "list1")

        XCTAssertTrue(tasks.isEmpty)
    }

    // MARK: - Parameter Passing

    func testListTasksShowCompletedFalsePassesQueryParam() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, #"{"items":[]}"#.data(using: .utf8)!)
        }

        _ = try await api.listTasks(listId: "list1", showCompleted: false, showHidden: false)

        let url = MockURLProtocol.requestLog.last!.url!.absoluteString
        XCTAssertTrue(url.contains("showCompleted=false"))
        XCTAssertTrue(url.contains("showHidden=false"))
    }

    func testListTasksShowCompletedTruePassesQueryParam() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, #"{"items":[]}"#.data(using: .utf8)!)
        }

        _ = try await api.listTasks(listId: "list1", showCompleted: true, showHidden: true)

        let url = MockURLProtocol.requestLog.last!.url!.absoluteString
        XCTAssertTrue(url.contains("showCompleted=true"))
        XCTAssertTrue(url.contains("showHidden=true"))
    }

    func testListTasksMaxResultsParam() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, #"{"items":[]}"#.data(using: .utf8)!)
        }

        _ = try await api.listTasks(listId: "list1")

        let url = MockURLProtocol.requestLog.last!.url!.absoluteString
        XCTAssertTrue(url.contains("maxResults=100"))
    }

    func testListTasksIncludesAuthorizationHeader() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, #"{"items":[]}"#.data(using: .utf8)!)
        }

        _ = try await api.listTasks(listId: "list1")

        let authHeader = MockURLProtocol.requestLog.last!.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(authHeader, "Bearer test-token")
    }

    // MARK: - Error Handling

    func testListTasksThrowsUnauthorizedOn401() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        do {
            _ = try await api.listTasks(listId: "list1")
            XCTFail("Expected unauthorized error")
        } catch let error as APIError {
            if case .unauthorized = error {
                // Expected
            } else {
                XCTFail("Expected .unauthorized, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testListTasksThrowsServerErrorOn500() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            let body = "Internal Server Error"
            return (response, body.data(using: .utf8)!)
        }

        do {
            _ = try await api.listTasks(listId: "list1")
            XCTFail("Expected server error")
        } catch let error as APIError {
            if case .serverError(let code, let message) = error {
                XCTAssertEqual(code, 500)
                XCTAssertEqual(message, "Internal Server Error")
            } else {
                XCTFail("Expected .serverError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testListTasksThrowsDecodingErrorOnBadJSON() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "not json".data(using: .utf8)!)
        }

        do {
            _ = try await api.listTasks(listId: "list1")
            XCTFail("Expected decoding error")
        } catch let error as APIError {
            if case .decodingError = error {
                // Expected
            } else {
                XCTFail("Expected .decodingError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testListTasksThrowsNetworkErrorOnURLError() async {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        do {
            _ = try await api.listTasks(listId: "list1")
            XCTFail("Expected network error")
        } catch let error as APIError {
            if case .networkError(let urlError) = error {
                XCTAssertEqual(urlError.code, .notConnectedToInternet)
            } else {
                XCTFail("Expected .networkError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - createTask

    func testCreateTaskSendsPostWithJSON() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"id":"new1","title":"Buy milk","status":"needsAction"}"#
            return (response, json.data(using: .utf8)!)
        }

        let task = try await api.createTask(listId: "list1", title: "Buy milk")

        XCTAssertEqual(task.id, "new1")
        XCTAssertEqual(task.title, "Buy milk")
        let lastRequest = MockURLProtocol.requestLog.last!
        XCTAssertEqual(lastRequest.httpMethod, "POST")
        XCTAssertEqual(lastRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testCreateTaskWithNotesAndDue() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"id":"new1","title":"Meeting","status":"needsAction","notes":"Room 3","due":"2026-04-01T00:00:00.000Z"}"#
            return (response, json.data(using: .utf8)!)
        }

        let task = try await api.createTask(listId: "list1", title: "Meeting", notes: "Room 3", due: "2026-04-01T00:00:00.000Z")

        XCTAssertEqual(task.id, "new1")
        XCTAssertEqual(task.title, "Meeting")
        XCTAssertEqual(task.notes, "Room 3")
        XCTAssertEqual(task.due, "2026-04-01T00:00:00.000Z")
        let lastRequest = MockURLProtocol.requestLog.last!
        XCTAssertEqual(lastRequest.httpMethod, "POST")
        XCTAssertEqual(lastRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    // MARK: - deleteTask

    func testDeleteTaskSendsDeleteMethod() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        try await api.deleteTask(listId: "list1", taskId: "t1")

        XCTAssertEqual(MockURLProtocol.requestLog.last!.httpMethod, "DELETE")
    }

    // MARK: - updateTask

    func testUpdateTaskSendsPatchMethod() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"id":"t1","title":"Updated","status":"completed"}"#
            return (response, json.data(using: .utf8)!)
        }

        let task = TaskItem(id: "t1", title: "Updated", notes: nil, status: .completed, due: nil, selfLink: nil, parent: nil, position: nil, updated: nil)
        let result = try await api.updateTask(listId: "list1", taskId: "t1", task: task)

        XCTAssertEqual(MockURLProtocol.requestLog.last!.httpMethod, "PATCH")
        XCTAssertEqual(result.title, "Updated")
        XCTAssertTrue(result.isCompleted)
    }

    func testUpdateTaskSendsNullForClearedDueAndNotes() async throws {
        Self.capturedRequestBody = nil
        MockURLProtocol.requestHandler = { request in
            Self.capturedRequestBody = requestBodyData(from: request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"id":"t1","title":"Updated","status":"needsAction"}"#
            return (response, json.data(using: .utf8)!)
        }

        let task = TaskItem(
            id: "t1",
            title: "Updated",
            notes: nil,
            status: .needsAction,
            due: nil,
            selfLink: nil,
            parent: nil,
            position: nil,
            updated: nil
        )

        _ = try await api.updateTask(listId: "list1", taskId: "t1", task: task)

        let bodyData = try XCTUnwrap(Self.capturedRequestBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

        XCTAssertEqual(body["title"] as? String, "Updated")
        XCTAssertEqual(body["status"] as? String, "needsAction")
        XCTAssertTrue(body["notes"] is NSNull)
        XCTAssertTrue(body["due"] is NSNull)
    }

    // MARK: - listTaskLists

    func testListTaskListsReturnsLists() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"items":[{"id":"l1","title":"My Tasks"},{"id":"l2","title":"Work"}]}"#
            return (response, json.data(using: .utf8)!)
        }

        let lists = try await api.listTaskLists()

        XCTAssertEqual(lists.count, 2)
        XCTAssertEqual(lists[0].id, "l1")
        XCTAssertEqual(lists[1].title, "Work")
        XCTAssertTrue(MockURLProtocol.requestLog.last!.url!.absoluteString.contains("/users/@me/lists"))
    }

    func testListTaskListsEmptyReturnsEmptyArray() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, #"{"kind":"tasks#taskLists"}"#.data(using: .utf8)!)
        }

        let lists = try await api.listTaskLists()

        XCTAssertTrue(lists.isEmpty)
    }

    // MARK: - moveTask

    func testMoveTaskSendsPostWithQueryParams() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"id":"t1","title":"Moved","status":"needsAction"}"#
            return (response, json.data(using: .utf8)!)
        }

        let result = try await api.moveTask(listId: "list1", taskId: "t1", previousId: "t0", parentId: "parent1")

        let lastRequest = MockURLProtocol.requestLog.last!
        XCTAssertEqual(lastRequest.httpMethod, "POST")
        let url = lastRequest.url!.absoluteString
        XCTAssertTrue(url.contains("/move"))
        XCTAssertTrue(url.contains("previous=t0"))
        XCTAssertTrue(url.contains("parent=parent1"))
        XCTAssertEqual(result.id, "t1")
    }
}

private func requestBodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }

    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)

    while stream.hasBytesAvailable {
        let bytesRead = stream.read(&buffer, maxLength: buffer.count)
        guard bytesRead > 0 else { break }
        data.append(buffer, count: bytesRead)
    }

    return data
}
