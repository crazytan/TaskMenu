import Foundation
import MetricKit
import OSLog

struct MetricKitPayloadStore: Sendable {
    enum PayloadKind: String, Sendable {
        case metric
        case diagnostic
    }

    enum PayloadSource: String, Sendable {
        case delivered
        case past
    }

    let directoryURL: URL

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
        payloads: [Data],
        date: Date = Date()
    ) throws -> [URL] {
        guard !payloads.isEmpty else {
            return []
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        return try payloads.map { payload in
            let fileURL = directoryURL.appendingPathComponent(
                "\(Self.timestamp(date))-\(source.rawValue)-\(kind.rawValue)-\(UUID().uuidString).json",
                isDirectory: false
            )
            try payload.write(to: fileURL, options: .atomic)
            return fileURL
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let milliseconds = Int(date.timeIntervalSince1970 * 1000)
        return String(milliseconds)
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
