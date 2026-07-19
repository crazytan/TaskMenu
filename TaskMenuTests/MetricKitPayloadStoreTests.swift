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

        let urls = try store.save(kind: .diagnostic, source: .delivered, payloads: [payload])

        XCTAssertEqual(urls.count, 1)
        XCTAssertTrue(urls[0].lastPathComponent.hasPrefix("delivered-diagnostic-"))
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
            ]
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

    func testSaveSamePayloadTwiceYieldsOneFile() throws {
        let store = MetricKitPayloadStore(directoryURL: temporaryDirectory)
        let payload = Data(#"{"metric":"repeat"}"#.utf8)

        let firstURLs = try store.save(kind: .metric, source: .past, payloads: [payload])
        let secondURLs = try store.save(kind: .metric, source: .past, payloads: [payload])

        XCTAssertEqual(firstURLs.count, 1)
        XCTAssertTrue(secondURLs.isEmpty)
        XCTAssertEqual(try storedFileNames().count, 1)
    }

    func testSaveSkipsPayloadAlreadyStoredUnderAnotherSource() throws {
        let store = MetricKitPayloadStore(directoryURL: temporaryDirectory)
        let payload = Data(#"{"diagnostics":["crash"]}"#.utf8)

        let deliveredURLs = try store.save(kind: .diagnostic, source: .delivered, payloads: [payload])
        let pastURLs = try store.save(kind: .diagnostic, source: .past, payloads: [payload])

        XCTAssertEqual(deliveredURLs.count, 1)
        XCTAssertTrue(pastURLs.isEmpty)
        XCTAssertEqual(try storedFileNames(), [deliveredURLs[0].lastPathComponent])
    }

    func testSaveKeepsSameContentAcrossKinds() throws {
        let store = MetricKitPayloadStore(directoryURL: temporaryDirectory)
        let payload = Data(#"{"shared":true}"#.utf8)

        let metricURLs = try store.save(kind: .metric, source: .delivered, payloads: [payload])
        let diagnosticURLs = try store.save(kind: .diagnostic, source: .delivered, payloads: [payload])

        XCTAssertEqual(metricURLs.count, 1)
        XCTAssertEqual(diagnosticURLs.count, 1)
        XCTAssertEqual(try storedFileNames().count, 2)
    }

    func testPruneRemovesFilesOlderThanRetentionWindow() throws {
        let store = MetricKitPayloadStore(directoryURL: temporaryDirectory)
        let now = Date(timeIntervalSince1970: 100 * 24 * 60 * 60)
        let retention: TimeInterval = 30 * 24 * 60 * 60

        let oldURLs = try store.save(kind: .metric, source: .past, payloads: [Data(#"{"metric":"old"}"#.utf8)])
        try setModificationDate(now.addingTimeInterval(-retention - 1), for: oldURLs[0])
        let recentURLs = try store.save(kind: .metric, source: .past, payloads: [Data(#"{"metric":"recent"}"#.utf8)])
        try setModificationDate(now.addingTimeInterval(-retention + 60), for: recentURLs[0])

        let deleted = try store.prune(retentionInterval: retention, maxFileCount: 10, now: now)

        // Compare file names, not URLs: prune enumerates the directory, which may spell the
        // temp dir as /private/var/... while save-built URLs use /var/..., depending on the
        // Foundation version.
        XCTAssertEqual(deleted.map(\.lastPathComponent), oldURLs.map(\.lastPathComponent))
        XCTAssertEqual(try storedFileNames(), [recentURLs[0].lastPathComponent])
    }

    func testPruneDeletesOldestFilesBeyondMaxFileCount() throws {
        let store = MetricKitPayloadStore(directoryURL: temporaryDirectory)
        let now = Date(timeIntervalSince1970: 10 * 24 * 60 * 60)
        var urlsByAge: [URL] = []
        for index in 0..<5 {
            let urls = try store.save(
                kind: .metric,
                source: .past,
                payloads: [Data(#"{"metric":\#(index)}"#.utf8)]
            )
            try setModificationDate(now.addingTimeInterval(TimeInterval(-3600 * (5 - index))), for: urls[0])
            urlsByAge.append(urls[0])
        }

        let deleted = try store.prune(retentionInterval: 30 * 24 * 60 * 60, maxFileCount: 3, now: now)

        XCTAssertEqual(
            Set(deleted.map(\.lastPathComponent)),
            Set(urlsByAge.prefix(2).map(\.lastPathComponent))
        )
        XCTAssertEqual(
            Set(try storedFileNames()),
            Set(urlsByAge.suffix(3).map(\.lastPathComponent))
        )
    }

    func testPruneWithMissingDirectoryDeletesNothing() throws {
        let store = MetricKitPayloadStore(directoryURL: temporaryDirectory)

        let deleted = try store.prune()

        XCTAssertTrue(deleted.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDirectory.path))
    }

    private func storedFileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
    }

    private func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
