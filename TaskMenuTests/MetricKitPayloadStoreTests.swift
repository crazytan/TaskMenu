import Foundation
import XCTest
@testable import TaskMenu

final class MetricKitPayloadStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskMenuMetricKitTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testSaveWritesPayloadJSON() throws {
        let store = MetricKitPayloadStore(directoryURL: temporaryDirectory)
        let payload = Data(#"{"diagnostics":[]}"#.utf8)

        let urls = try store.save(
            kind: .diagnostic,
            source: .delivered,
            payloads: [payload],
            date: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(urls.count, 1)
        XCTAssertTrue(urls[0].lastPathComponent.contains("1000-delivered-diagnostic"))
        XCTAssertEqual(try Data(contentsOf: urls[0]), payload)
    }

    func testSaveCreatesOneFilePerPayload() throws {
        let store = MetricKitPayloadStore(directoryURL: temporaryDirectory)

        let urls = try store.save(
            kind: .metric,
            source: .past,
            payloads: [
                Data(#"{"metric":1}"#.utf8),
                Data(#"{"metric":2}"#.utf8)
            ],
            date: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(Set(urls.map(\.lastPathComponent)).count, 2)
        XCTAssertTrue(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testSaveSkipsEmptyPayloads() throws {
        let store = MetricKitPayloadStore(directoryURL: temporaryDirectory)

        let urls = try store.save(kind: .metric, source: .delivered, payloads: [])

        XCTAssertTrue(urls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDirectory.path))
    }
}
