import Testing
@testable import CodexPetNotch

struct CodexRealtimeStateTests {
    @Test func parsesRealtimeStartAndStop() {
        let id = "019fa10f-77de-7fa2-a874-7ed0a9f9060f"
        let start = "response_routed conversationId=\(id) method=thread/realtime/start"
        let stop = "response_routed conversationId=\(id) method=thread/realtime/stop"

        #expect(CodexTaskMonitor.realtimeThreadEvent(from: start)?.id == id)
        #expect(CodexTaskMonitor.realtimeThreadEvent(from: start)?.isActive == true)
        #expect(CodexTaskMonitor.realtimeThreadEvent(from: stop)?.id == id)
        #expect(CodexTaskMonitor.realtimeThreadEvent(from: stop)?.isActive == false)
    }

    @Test func ignoresUnrelatedDesktopEvents() {
        #expect(CodexTaskMonitor.realtimeThreadEvent(from: "method=thread/read") == nil)
    }

    @Test func parsesDesktopTurnLifecycle() {
        let id = "019f6f42-9fb3-7dd0-a1f1-b2e3f53851a4"
        let start = "2026-07-27T07:28:43.193Z info response_routed conversationId=\(id) method=turn/start"
        let complete = "2026-07-27T07:30:55.540Z info [desktop-notifications] show turn-complete conversationId=\(id)"

        #expect(CodexTaskMonitor.desktopTurnEvent(from: start)?.id == id)
        #expect(CodexTaskMonitor.desktopTurnEvent(from: start)?.isActive == true)
        #expect(CodexTaskMonitor.desktopTurnEvent(from: complete)?.id == id)
        #expect(CodexTaskMonitor.desktopTurnEvent(from: complete)?.isActive == false)
    }
}
