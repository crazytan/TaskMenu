import Foundation
import XCTest

/// A mock URL protocol for intercepting HTTP requests in tests.
/// Set `requestHandler` before each test to return custom responses.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    /// Handler called for each intercepted request. Must return an HTTP response and data.
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    /// Tracks URLs of all intercepted requests (reset in setUp).
    nonisolated(unsafe) static var requestLog: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestLog.append(request)

        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    // MARK: - Helpers

    /// Creates a URLSession configured to use this mock protocol.
    static func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Resets the handler and request log. Call in setUp().
    static func reset() {
        requestHandler = nil
        requestLog = []
    }
}
