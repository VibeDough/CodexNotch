import Foundation
import Testing
@testable import CodexPetNotch

@Test func newThreadUsesSupportedRouteAndPreservesPrompt() throws {
    let url = try #require(CodexDeepLink.newThread(prompt: "分析 /tmp/示例 1.png"))
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

    #expect(components.scheme == "codex")
    #expect(components.host == "threads")
    #expect(components.path == "/new")
    #expect(components.queryItems?.first { $0.name == "prompt" }?.value == "分析 /tmp/示例 1.png")
}
