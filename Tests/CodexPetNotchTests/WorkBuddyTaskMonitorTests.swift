import Testing
@testable import CodexPetNotch

struct WorkBuddyTaskMonitorTests {
    @Test func parsesPhaseAndSessionFromRendererLog() {
        let id = "1e02f2d4-1d86-47bd-96d6-375c91f3785c"
        let line = #"{"timestamp":"2026-07-27T09:10:04.974Z","message":["[renderer] [WorkbuddyAdapter] Phase update: phase.tool_executing.Read (session=\#(id))"]}"#
        let event = WorkBuddyTaskMonitor.phaseEvent(from: line)

        #expect(event?.id == id)
        #expect(event?.phase == "phase.tool_executing.Read")
        #expect(event?.date != nil)
    }

    @Test func ignoresUnrelatedRendererMessages() {
        #expect(WorkBuddyTaskMonitor.phaseEvent(from: #"{"timestamp":"2026-07-27T09:10:04.974Z","message":["SessionStore read done"]}"#) == nil)
    }
}
