import Testing
@testable import CodexPetNotch

@Suite struct CodexUserInputTrackerTests {
    @Test func parsesRequestAndQuestion() {
        let payload: [String: Any] = [
            "type": "function_call",
            "name": "request_user_input",
            "call_id": "call-1",
            "arguments": #"{"questions":[{"question":"首版先验证哪一层？"}]}"#
        ]

        #expect(CodexTaskMonitor.userInputEvent(from: payload) == .requested(
            id: "call-1",
            question: "首版先验证哪一层？"
        ))
    }

    @Test func matchingAnswerClearsRequest() {
        var tracker = CodexUserInputTracker()

        #expect(tracker.ingest(.requested(id: "call-1", question: "问题")))
        #expect(tracker.isWaiting)
        #expect(tracker.ingest(.answered(id: "call-1")))
        #expect(!tracker.isWaiting)
    }

    @Test func waitsUntilEveryRequestIsAnswered() {
        var tracker = CodexUserInputTracker()
        tracker.ingest(.requested(id: "call-1", question: "问题一"))
        tracker.ingest(.requested(id: "call-2", question: "问题二"))

        #expect(tracker.ingest(.answered(id: "call-1")))
        #expect(tracker.isWaiting)
        #expect(tracker.firstQuestion == "问题二")
        #expect(tracker.ingest(.answered(id: "call-2")))
        #expect(!tracker.isWaiting)
    }

    @Test func ignoresUnrelatedCallsAndOutputs() {
        let unrelatedCall: [String: Any] = [
            "type": "function_call",
            "name": "exec",
            "call_id": "call-1"
        ]
        let unrelatedOutput: [String: Any] = [
            "type": "function_call_output",
            "call_id": "other-call"
        ]
        var tracker = CodexUserInputTracker()

        #expect(CodexTaskMonitor.userInputEvent(from: unrelatedCall) == nil)
        #expect(CodexTaskMonitor.userInputEvent(from: unrelatedOutput) == .answered(id: "other-call"))
        #expect(!tracker.ingest(.answered(id: "other-call")))
        #expect(!tracker.isWaiting)
    }
}
