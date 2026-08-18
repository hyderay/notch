import Foundation
import NotchCore

struct AvailableUpdate {
    let currentVersion: String
    let latestVersion: String
    let releaseURL: URL
}

enum UpdateCheckResult {
    case upToDate(currentVersion: String)
    case updateAvailable(AvailableUpdate)
}

enum UpdateCheckError: LocalizedError {
    case invalidCurrentVersion(String)
    case invalidResponse
    case invalidReleaseVersion(String)

    var errorDescription: String? {
        switch self {
        case let .invalidCurrentVersion(version):
            return "The installed version \(version) is not valid."
        case .invalidResponse:
            return "GitHub returned an invalid response."
        case let .invalidReleaseVersion(version):
            return "The latest release version \(version) is not valid."
        }
    }
}

enum UpdateChecker {
    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    private static let apiURL = URL(string: "https://api.github.com/repos/hyderay/notch/releases/latest")!

    static var currentVersionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }

    static func check() async throws -> UpdateCheckResult {
        let currentString = currentVersionString
        guard let current = SemanticVersion(currentString) else {
            throw UpdateCheckError.invalidCurrentVersion(currentString)
        }

        var request = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Notch/\(currentString)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateCheckError.invalidResponse
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let latest = SemanticVersion(release.tagName) else {
            throw UpdateCheckError.invalidReleaseVersion(release.tagName)
        }
        let latestString = release.tagName.first.map { $0 == "v" || $0 == "V" } == true
            ? String(release.tagName.dropFirst())
            : release.tagName

        if current < latest {
            return .updateAvailable(
                AvailableUpdate(
                    currentVersion: currentString,
                    latestVersion: latestString,
                    releaseURL: release.htmlURL
                )
            )
        }
        return .upToDate(currentVersion: currentString)
    }
}
