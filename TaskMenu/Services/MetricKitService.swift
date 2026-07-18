import CryptoKit
import Foundation
import MetricKit
import OSLog

struct MetricKitPayloadStore: Sendable {
    enum PayloadKind: String, Sendable {
        case metric
        case diagnostic
    }

    enum PayloadSource: String, Sendable, CaseIterable {
        case delivered
        case past
    }

    let directoryURL: URL

    static let defaultRetentionInterval: TimeInterval = 30 * 24 * 60 * 60
    static let defaultMaxFileCount = 200

    static var defaultDirectoryURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser

        return applicationSupport
            .appendingPathComponent("TaskMenu", isDirectory: true)
            .appendingPathComponent("MetricKit", isDirectory: true)
    }

    static let `default` = MetricKitPayloadStore(directoryURL: defaultDirectoryURL)

    @discardableResult
    func save(
        kind: PayloadKind,
        source: PayloadSource,
        payloads: [Data]
    ) throws -> [URL] {
        guard !payloads.isEmpty else {
            return []
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        return try payloads.compactMap { payload in
            let hash = Self.contentHash(payload)
            // MetricKit re-reports past payloads for days, and payloads delivered live are
            // reported again as "past" on later launches; skip any content already on disk
            // under either source so re-persisting is idempotent.
            let alreadyStored = PayloadSource.allCases.contains { existingSource in
                fileManager.fileExists(
                    atPath: fileURL(source: existingSource, kind: kind, hash: hash).path
                )
            }
            guard !alreadyStored else {
                return nil
            }

            let destinationURL = fileURL(source: source, kind: kind, hash: hash)
            try payload.write(to: destinationURL, options: .atomic)
            return destinationURL
        }
    }

    @discardableResult
    func prune(
        retentionInterval: TimeInterval = MetricKitPayloadStore.defaultRetentionInterval,
        maxFileCount: Int = MetricKitPayloadStore.defaultMaxFileCount,
        now: Date = Date()
    ) throws -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return []
        }

        let contents = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        var entries = contents.map { url in
            let modificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return (url: url, date: modificationDate)
        }
        entries.sort { $0.date > $1.date }

        let cutoff = now.addingTimeInterval(-retentionInterval)
        var deleted: [URL] = []
        for (index, entry) in entries.enumerated() where index >= maxFileCount || entry.date < cutoff {
            try fileManager.removeItem(at: entry.url)
            deleted.append(entry.url)
        }
        return deleted
    }

    private func fileURL(source: PayloadSource, kind: PayloadKind, hash: String) -> URL {
        directoryURL.appendingPathComponent(
            "\(source.rawValue)-\(kind.rawValue)-\(hash).json",
            isDirectory: false
        )
    }

    private static func contentHash(_ payload: Data) -> String {
        SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }
}

final class MetricKitService: NSObject, MXMetricManagerSubscriber {
    private let store: MetricKitPayloadStore
    private let logger: Logger
    private var isStarted = false

    init(
        store: MetricKitPayloadStore = .default,
        logger: Logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TaskMenu", category: "MetricKit")
    ) {
        self.store = store
        self.logger = logger
        super.init()
    }

    @MainActor
    func start() {
        guard !isStarted else {
            return
        }

        isStarted = true

        let manager = MXMetricManager.shared
        manager.add(self)

        pruneStoredPayloads()
        persistMetricPayloads(manager.pastPayloads, source: .past)
        persistDiagnosticPayloads(manager.pastDiagnosticPayloads, source: .past)

        logger.info("MetricKit diagnostics enabled at \(self.store.directoryURL.path, privacy: .public)")
    }

    @MainActor
    func stop() {
        guard isStarted else {
            return
        }

        MXMetricManager.shared.remove(self)
        isStarted = false
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        persistMetricPayloads(payloads, source: .delivered)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        persistDiagnosticPayloads(payloads, source: .delivered)
    }

    private func pruneStoredPayloads() {
        do {
            let deleted = try store.prune()
            guard !deleted.isEmpty else {
                return
            }

            logger.info("Pruned \(deleted.count) stored MetricKit payload file(s)")
        } catch {
            logger.error("Failed to prune stored MetricKit payloads: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistMetricPayloads(_ payloads: [MXMetricPayload], source: MetricKitPayloadStore.PayloadSource) {
        persist(payloads.map { $0.jsonRepresentation() }, kind: .metric, source: source)
    }

    private func persistDiagnosticPayloads(
        _ payloads: [MXDiagnosticPayload],
        source: MetricKitPayloadStore.PayloadSource
    ) {
        persist(payloads.map { $0.jsonRepresentation() }, kind: .diagnostic, source: source)
    }

    private func persist(
        _ payloads: [Data],
        kind: MetricKitPayloadStore.PayloadKind,
        source: MetricKitPayloadStore.PayloadSource
    ) {
        do {
            let urls = try store.save(kind: kind, source: source, payloads: payloads)
            guard !urls.isEmpty else {
                return
            }

            logger.info("Saved \(urls.count) MetricKit \(kind.rawValue, privacy: .public) payload(s)")
        } catch {
            logger.error("Failed to save MetricKit \(kind.rawValue, privacy: .public) payloads: \(error.localizedDescription, privacy: .public)")
        }

        // TODO: Upload persisted MetricKit payloads after adding explicit user opt-in and backend support.
    }
}
