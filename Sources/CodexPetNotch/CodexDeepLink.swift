import Foundation

enum CodexDeepLink {
    static func newThread(prompt: String) -> URL? {
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/new"
        components.queryItems = [URLQueryItem(name: "prompt", value: prompt)]
        return components.url
    }
}
