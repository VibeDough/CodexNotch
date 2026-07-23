import Foundation

struct AppUpdateInfo: Equatable {
    let version: String
    let releaseURL: URL
    let downloadURL: URL
}

enum AppVersion {
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        normalized(candidate).compare(normalized(current), options: .numeric) == .orderedDescending
    }

    private static func normalized(_ version: String) -> String {
        version.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
    }
}

enum AppUpdateChecker {
    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let htmlURL: URL
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    static func latestRelease() async throws -> AppUpdateInfo {
        let endpoint = URL(string: "https://api.github.com/repos/VibeDough/CodexNotch/releases/latest")!
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodexNotch", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let downloadURL = release.assets.first {
            $0.name.lowercased().hasSuffix(".dmg") && $0.name.lowercased().contains("arm64")
        }?.browserDownloadURL ?? release.htmlURL
        return AppUpdateInfo(
            version: release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")),
            releaseURL: release.htmlURL,
            downloadURL: downloadURL
        )
    }
}
