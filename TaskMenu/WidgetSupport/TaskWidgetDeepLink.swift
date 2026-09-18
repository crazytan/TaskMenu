import Foundation

/// Strict `taskmenu://widget/list?id=<percent-encoded google list id>` deep
/// link. This type only builds and parses the URL; routing it into the
/// popover (activating TaskMenu, bootstrapping lists, calling
/// `AppState.selectList`, presenting `StatusBarController`) is app-only
/// behavior owned elsewhere, not this file.
enum TaskWidgetDeepLink: Sendable, Equatable {
    case list(id: String)

    /// Conservative bound on the `id` query value, matching the contract.
    /// Google list ids are short; this only guards against a pathological
    /// or malicious URL, not a realistic id.
    static let maxListIDLength = 512

    private static let host = "widget"
    private static let listPath = "/list"

    /// Builds a `taskmenu://widget/list?id=...` URL for `listID`. Returns
    /// `nil` for an id that could never round-trip through `parse(_:)`
    /// (empty or over `maxListIDLength`) rather than producing a URL this
    /// type would itself reject.
    static func url(forListID listID: String) -> URL? {
        guard !listID.isEmpty, listID.count <= maxListIDLength else { return nil }

        var components = URLComponents()
        components.scheme = TaskWidgetConstants.deepLinkScheme
        components.host = host
        components.path = listPath
        components.queryItems = [URLQueryItem(name: "id", value: listID)]
        return components.url
    }

    /// Parses `url` into a `TaskWidgetDeepLink`. Accepts only:
    /// - scheme `taskmenu`;
    /// - host `widget`;
    /// - path `/list`;
    /// - exactly one query item named `id` with a nonempty value no longer
    ///   than `maxListIDLength`.
    ///
    /// Anything else — wrong scheme/host/path, a missing, duplicate, or
    /// empty `id`, or an oversized `id` — parses to `nil`. This function has
    /// no side effects; it never activates the app or touches `AppState`.
    static func parse(_ url: URL) -> TaskWidgetDeepLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        guard components.scheme == TaskWidgetConstants.deepLinkScheme else { return nil }
        guard components.host == host else { return nil }
        guard components.path == listPath else { return nil }

        let idQueryItems = (components.queryItems ?? []).filter { $0.name == "id" }
        guard idQueryItems.count == 1,
              let id = idQueryItems[0].value,
              !id.isEmpty,
              id.count <= maxListIDLength
        else {
            return nil
        }

        return .list(id: id)
    }
}
