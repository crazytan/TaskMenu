import Foundation

struct AppUpdateRelease: Equatable, Sendable {
    let version: String
    let displayVersion: String
    let releaseURL: URL
    let publishedAt: Date?
}

protocol UpdateChecking: Sendable {
    func latestUpdate(currentVersion: String) async throws -> AppUpdateRelease?
}

enum UpdateCheckError: LocalizedError, Sendable {
    case invalidResponse
    case serverError(Int)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub returned an invalid response."
        case .serverError(let statusCode):
            return "GitHub returned status \(statusCode)."
        case .decodingFailed:
            return "Failed to parse GitHub release information."
        }
    }
}

struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let versionString: Substring
        if trimmed.first == "v" || trimmed.first == "V" {
            versionString = trimmed.dropFirst()
        } else {
            versionString = Substring(trimmed)
        }

        let parts = versionString.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]),
              major >= 0,
              minor >= 0,
              patch >= 0 else {
            return nil
        }

        self.major = major
        self.minor = minor
        self.patch = patch
    }

    var description: String {
        "\(major).\(minor).\(patch)"
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

/// Reports "no update" without touching the network. Mac App Store builds use
/// it in place of `GitHubUpdateChecker`, which they do not compile, and the
/// `--testing-window` fakes use it to keep launches offline.
struct DisabledUpdateChecker: UpdateChecking {
    func latestUpdate(currentVersion: String) async throws -> AppUpdateRelease? {
        nil
    }
}

// The Mac App Store delivers its own updates, and guideline 2.4.5(vii) forbids
// shipping a second update path alongside it, so the GitHub checker is compiled
// out of that configuration entirely rather than just hidden in the UI.
#if !APP_STORE_BUILD
actor GitHubUpdateChecker: UpdateChecking {
    private let session: URLSession
    private let latestReleaseURL: URL

    init(session: URLSession = .shared) {
        guard let latestReleaseURL = URL(string: Constants.githubLatestReleaseURL) else {
            preconditionFailure("Invalid GitHub latest release URL.")
        }

        self.session = session
        self.latestReleaseURL = latestReleaseURL
    }

    init(session: URLSession = .shared, latestReleaseURL: URL) {
        self.session = session
        self.latestReleaseURL = latestReleaseURL
    }

    func latestUpdate(currentVersion: String) async throws -> AppUpdateRelease? {
        // A non-semver current version means a dev/test build (release builds
        // pin MARKETING_VERSION to x.y.z). Treat it as "no update" instead of
        // an error so such builds do not show a permanent failed check.
        guard let currentVersion = SemanticVersion(currentVersion) else { return nil }

        let response = try await latestRelease()
        // An unparseable release tag is a malformed release, not "up to date";
        // surface it as a failed check.
        guard let releaseVersion = SemanticVersion(response.tagName) else {
            throw UpdateCheckError.decodingFailed("Unrecognized release tag \(response.tagName).")
        }
        guard releaseVersion > currentVersion else {
            return nil
        }

        return AppUpdateRelease(
            version: releaseVersion.description,
            displayVersion: response.displayName,
            releaseURL: response.htmlURL,
            publishedAt: response.publishedAt
        )
    }

    private func latestRelease() async throws -> GitHubLatestReleaseResponse {
        var request = URLRequest(url: latestReleaseURL)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TaskMenu", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw UpdateCheckError.serverError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            return try decoder.decode(GitHubLatestReleaseResponse.self, from: data)
        } catch {
            throw UpdateCheckError.decodingFailed(error.localizedDescription)
        }
    }
}

private struct GitHubLatestReleaseResponse: Decodable {
    let tagName: String
    let htmlURL: URL
    let name: String?
    let publishedAt: Date?

    var displayName: String {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return tagName
        }
        return name
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case name
        case publishedAt = "published_at"
    }
}
#endif
