import Testing
@testable import CodexPetNotch

@Suite struct CodexTaskRuntimeTrackerTests {
    @Test func tracksCurrentToolUntilMatchingOutput() {
        var tracker = CodexTaskRuntimeTracker()
        tracker.taskDidStart()
        tracker.toolCalled(id: "call-1", name: "imagegen", arguments: nil)

        #expect(tracker.currentTool?.label == AppLanguage.text("生成图片", "Generating image"))
        #expect(tracker.currentTool?.systemImage == "photo.badge.plus")

        tracker.toolFinished(id: "call-1")
        #expect(tracker.currentTool == nil)
    }

    @Test func recordsSubtaskHierarchyFromSpawnAgent() {
        var tracker = CodexTaskRuntimeTracker()
        tracker.taskDidStart()
        tracker.toolCalled(
            id: "call-agent",
            name: "spawn_agent",
            arguments: #"{"task_name":"inspect_ui","message":"检查界面"}"#
        )

        #expect(tracker.subtasks == [CodexSubtask(id: "call-agent", name: "inspect ui")])
    }

    @Test func countsOnlyMessagesQueuedAfterTaskStarts() {
        var tracker = CodexTaskRuntimeTracker()
        tracker.userMessageArrived()
        #expect(tracker.queuedMessageCount == 0)

        tracker.taskDidStart()
        tracker.userMessageArrived()
        tracker.userMessageArrived()
        tracker.userMessageArrived()
        #expect(tracker.queuedMessageCount == 2)

        tracker.taskDidFinish()
        #expect(tracker.queuedMessageCount == 0)
    }

    @Test func parsesFunctionAndCustomToolRecords() {
        let call: [String: Any] = [
            "type": "function_call",
            "name": "spawn_agent",
            "call_id": "call-1",
            "arguments": #"{"task_name":"audit"}"#
        ]
        let output: [String: Any] = [
            "type": "function_call_output",
            "call_id": "call-1"
        ]

        #expect(CodexTaskMonitor.toolCall(from: call)?.name == "spawn_agent")
        #expect(CodexTaskMonitor.toolOutputID(from: output) == "call-1")
    }
}
