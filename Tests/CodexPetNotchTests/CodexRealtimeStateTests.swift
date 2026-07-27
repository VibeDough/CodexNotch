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
}
