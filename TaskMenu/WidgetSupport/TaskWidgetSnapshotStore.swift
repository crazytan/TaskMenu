import Foundation

/// Coordinated App Group reads/writes of `TaskWidgetSnapshot`. Both the app
/// and `TaskMenuWidget` construct their own instance pointed at the same
/// container; every mutation is `NSFileCoordinator`-coordinated so the two
/// processes never observe or produce a partially written file.
///
/// This type carries no mutable state of its own (`directoryURL` is the only
/// stored property), so every operation is safe to call from either process
/// without additional in-process locking. Cross-process ordering ambiguity
/// (an older request finishing after a newer one) is handled by
/// `replaceList(_:requestStartedAt:)`, not by serializing calls here.
///
/// Timestamp precision: every `Date` in `TaskWidgetSnapshot` round-trips
/// through disk at sub-second precision (see `makeEncoder()`/`makeDecoder()`).
/// The app and the widget extension can start and finish overlapping
/// requests less than a second apart, so a whole-second-only encoding would
/// make `replaceList(_:requestStartedAt:)`'s stale-write comparison
/// unreliable for same-second writes. Do not change the date strategy to
/// one that truncates fractional seconds.
struct TaskWidgetSnapshotStore: Sendable {
    enum StoreError: Error, Equatable {
        /// The App Group container could not be resolved: no entitlement
        /// (unsigned/dev build), the identifier is unset, or the OS
        /// returned no container URL. Normal, non-fatal state — callers
        /// should treat it as "widget data unavailable", not crash.
        case containerUnavailable
    }

    /// Directory the snapshot file lives in. `nil` means "no App Group
    /// available"; every mutating call throws `.containerUnavailable` and
    /// every read returns `.empty()`.
    let directoryURL: URL?

    /// Test/injected initializer. Creates `directoryURL` on disk if it does
    /// not already exist so tests can point at a fresh temporary directory
    /// without a separate setup step. Never touches the real App Group.
    init(directoryURL: URL?) {
        self.directoryURL = directoryURL
        if let directoryURL {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    /// Production initializer: resolves the App Group container from
    /// `SharedConstants.appGroupIdentifier`. A `nil` identifier or a `nil`
    /// container URL (missing entitlement, unregistered App Group) is a
    /// normal "unavailable" state.
    init() {
        if let identifier = SharedConstants.appGroupIdentifier,
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            self.init(directoryURL: container)
        } else {
            self.init(directoryURL: nil)
        }
    }

    private var fileURL: URL? {
        directoryURL?.appendingPathComponent(TaskWidgetConstants.snapshotFileName)
    }

    // MARK: Reading

    /// Reads the current snapshot. Never throws: a missing file, corrupt
    /// JSON, an unsupported future `schemaVersion`, or an unavailable
    /// container all resolve to `TaskWidgetSnapshot.empty()` so the widget
    /// gallery never crashes on bad shared state.
    func read() -> TaskWidgetSnapshot {
        guard let fileURL else { return .empty() }
        var result: TaskWidgetSnapshot?
        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: fileURL, options: [], error: &coordinatorError) { url in
            result = Self.decode(from: url)
        }
        return result ?? .empty()
    }

    // MARK: Writing (whole-snapshot replacement)

    /// Replaces the entire stored snapshot. Used for sign-in bootstrap
    /// (full rebuild) and, via `clear()`, sign-out/disconnect/demo-exit.
    func write(_ snapshot: TaskWidgetSnapshot) throws {
        try coordinatedMutate { $0 = snapshot }
    }

    /// Clears all widget-visible data. Callers must invoke this on explicit
    /// sign-out, account disconnect, and demo-mode exit so no stale task
    /// title survives in the shared cache or the widget UI.
    func clear() throws {
        try write(.empty(generatedAt: Date()))
    }

    // MARK: Targeted mutations

    /// Removes lists whose id is not in `validListIDs`, leaving every other
    /// list untouched. Call after an authoritative list-catalog fetch so a
    /// list deleted from another client stops rendering in installed
    /// widgets.
    func pruneLists(keeping validListIDs: Set<String>) throws {
        try coordinatedMutate { snapshot in
            snapshot.lists.removeAll { !validListIDs.contains($0.id) }
            snapshot.generatedAt = Date()
        }
    }

    func setDefaultListID(_ id: String?) throws {
        try coordinatedMutate { snapshot in
            snapshot.defaultListID = id
            snapshot.generatedAt = Date()
        }
    }

    func setAuthentication(_ state: TaskWidgetAuthenticationState) throws {
        try coordinatedMutate { snapshot in
            snapshot.authentication = state
            snapshot.generatedAt = Date()
        }
    }

    /// Authoritative list-replacement API with stale-write protection.
    ///
    /// The app and the widget extension can start overlapping Google
    /// requests for the same list and finish in either order because they
    /// are different processes racing the network, not just different
    /// threads. `requestStartedAt` must be the wall-clock time the network
    /// request that produced `list` *began*, not when it completed —
    /// otherwise a slow app-wide refresh that started before a widget
    /// completion could still stomp on it just by finishing later.
    ///
    /// Within one coordinated read-modify-write:
    /// 1. If a list with `list.id` is already stored and its `refreshedAt`
    ///    is later than `requestStartedAt`, the stored list is newer than
    ///    the request that produced `list` — reject and leave it untouched.
    /// 2. Otherwise store `list` in place of any existing entry with the
    ///    same id (or append it), preserving every other list and
    ///    `defaultListID`/`authentication`, and save atomically.
    ///
    /// Returns whether the write was accepted. Throws only for I/O/container
    /// failures, never for a stale rejection.
    @discardableResult
    func replaceList(_ list: TaskWidgetListSnapshot, requestStartedAt: Date) throws -> Bool {
        var accepted = false
        try coordinatedMutate { snapshot in
            if let index = snapshot.lists.firstIndex(where: { $0.id == list.id }) {
                let storedTimestamp = snapshot.lists[index].refreshedAt ?? snapshot.lists[index].refreshStartedAt
                if let storedTimestamp, storedTimestamp > requestStartedAt {
                    accepted = false
                    return
                }
                snapshot.lists[index] = list
            } else {
                snapshot.lists.append(list)
            }
            accepted = true
            snapshot.generatedAt = Date()
        }
        return accepted
    }

    // MARK: Coordinated I/O primitives

    /// Runs `transform` against the current on-disk snapshot (or `.empty()`
    /// when unreadable) inside a single `NSFileCoordinator` writing claim,
    /// then atomically saves the result. The read, transform, and write all
    /// happen while the coordinator holds the file, so a concurrent writer
    /// in this or another process cannot interleave with the
    /// read-modify-write.
    private func coordinatedMutate(_ transform: (inout TaskWidgetSnapshot) -> Void) throws {
        guard let fileURL else { throw StoreError.containerUnavailable }
        var coordinatorError: NSError?
        var thrownError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: fileURL, options: [], error: &coordinatorError) { url in
            var snapshot = Self.decode(from: url) ?? .empty()
            transform(&snapshot)
            do {
                try Self.atomicWrite(snapshot, to: url)
            } catch {
                thrownError = error
            }
        }
        if let coordinatorError {
            throw coordinatorError
        }
        if let thrownError {
            throw thrownError
        }
    }

    /// Decodes a snapshot from `url`. Returns `nil` (never throws) for a
    /// missing file, invalid JSON, or a `schemaVersion` greater than
    /// `TaskWidgetConstants.currentSchemaVersion` — every one of those is a
    /// "fail closed to empty" case for the caller, never a crash.
    private static func decode(from url: URL) -> TaskWidgetSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = Self.makeDecoder()
        guard let probe = try? decoder.decode(SchemaProbe.self, from: data),
              probe.schemaVersion <= TaskWidgetConstants.currentSchemaVersion
        else {
            return nil
        }
        return try? decoder.decode(TaskWidgetSnapshot.self, from: data)
    }

    /// Encodes and atomically replaces the file at `url`. `Data.write(options: .atomic)`
    /// writes to a temporary file in the same directory and renames it into
    /// place, so a concurrent reader always sees either the previous
    /// complete file or the new complete file, never a partial one.
    private static func atomicWrite(_ snapshot: TaskWidgetSnapshot, to url: URL) throws {
        let data = try Self.makeEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    /// `.secondsSince1970` encodes each `Date` as a JSON `Double` (seconds,
    /// with a fractional part), preserving sub-second precision. Do not
    /// switch this to `.iso8601`: `ISO8601DateFormatter`'s default options
    /// (as used by that strategy) truncate to whole seconds, which silently
    /// blunts `replaceList(_:requestStartedAt:)`'s stale-write protection —
    /// two writes less than a second apart would compare as equal and the
    /// older one would be wrongly accepted. See
    /// `TaskMenu/WidgetSupport/README.md`'s "Timestamp Precision" note.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    private struct SchemaProbe: Decodable {
        let schemaVersion: Int
    }
}
