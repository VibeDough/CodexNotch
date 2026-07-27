import Foundation

struct WorkBuddyStatusSnapshot {
    let tasks: [CodexTaskItem]
    let completedTask: CodexTaskItem?
}

final class WorkBuddyTaskMonitor {
    private struct SessionState {
        var phase: CodexActivity.Phase
        var label: String
        var startedAt: Date?
        var lastActivityAt: Date
        var toolActivity: CodexToolActivity?
    }

    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/WorkBuddy/renderer.log")
    private var readOffset: UInt64 = 0
    private var states: [String: SessionState] = [:]
    private var latestCompletion: CodexTaskItem?

    func latestSnapshot() -> WorkBuddyStatusSnapshot {
        ingestNewLogLines()
        let cutoff = Date().addingTimeInterval(-6 * 3_600)
        states = states.filter { $0.value.lastActivityAt >= cutoff }
        let tasks = states.compactMap { id, state -> CodexTaskItem? in
            guard [.running, .review, .inputRequired, .waiting].contains(state.phase) else { return nil }
            return task(id: id, state: state)
        }
        .sorted { $0.lastActivityAt > $1.lastActivityAt }
        let completion = latestCompletion.flatMap {
            Date().timeIntervalSince($0.lastActivityAt) < 8 ? $0 : nil
        }
        return WorkBuddyStatusSnapshot(tasks: tasks, completedTask: completion)
    }

    static func phaseEvent(from line: String) -> (id: String, phase: String, date: Date?)? {
        guard line.contains("[WorkbuddyAdapter] Phase update:"),
              let phaseRange = line.range(of: "Phase update: "),
              let sessionRange = line.range(of: " (session=", range: phaseRange.upperBound..<line.endIndex),
              let closing = line[sessionRange.upperBound...].firstIndex(of: ")") else { return nil }
        let phase = String(line[phaseRange.upperBound..<sessionRange.lowerBound])
        let id = String(line[sessionRange.upperBound..<closing])
        guard !id.isEmpty else { return nil }
        return (id, phase, logDate(from: line))
    }

    private func ingestNewLogLines() {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return }
        defer { try? handle.close() }
        let length = (try? handle.seekToEnd()) ?? 0
        if length < readOffset || readOffset == 0 {
            readOffset = length > 2_000_000 ? length - 2_000_000 : 0
        }
        guard length > readOffset else { return }
        try? handle.seek(toOffset: readOffset)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        readOffset = length
        for line in text.split(separator: "\n") {
            guard let event = Self.phaseEvent(from: String(line)) else { continue }
            apply(event)
        }
    }

    private func apply(_ event: (id: String, phase: String, date: Date?)) {
        let date = event.date ?? Date()
        var state = states[event.id] ?? SessionState(
            phase: .idle,
            label: AppLanguage.text("WorkBuddy 空闲", "WorkBuddy idle"),
            startedAt: nil,
            lastActivityAt: date,
            toolActivity: nil
        )
        state.lastActivityAt = date
        switch event.phase {
        case "cleared":
            state.phase = .completed
            state.label = AppLanguage.text("WorkBuddy 任务完成", "WorkBuddy task completed")
            state.toolActivity = nil
            states[event.id] = state
            latestCompletion = task(id: event.id, state: state)
            return
        case let value where value.hasPrefix("phase.waiting_for_permission.AskUserQuestion"):
            state.phase = .inputRequired
            state.label = AppLanguage.text("WorkBuddy 需要输入", "WorkBuddy input required")
            state.toolActivity = nil
        case let value where value.hasPrefix("phase.waiting_for_permission"):
            state.phase = .waiting
            state.label = AppLanguage.text("WorkBuddy 等待确认", "WorkBuddy waiting for confirmation")
            state.toolActivity = nil
        case let value where value.hasPrefix("phase.tool_executing."):
            let name = String(value.dropFirst("phase.tool_executing.".count))
            state.phase = .running
            state.toolActivity = CodexTaskRuntimeTracker.activity(name: name)
            state.label = state.toolActivity?.label
                ?? AppLanguage.text("WorkBuddy 正在使用工具", "WorkBuddy is using a tool")
        case let value where value.hasPrefix("phase.model_streaming."):
            let name = String(value.dropFirst("phase.model_streaming.".count))
            state.phase = .review
            state.toolActivity = CodexTaskRuntimeTracker.activity(name: name)
            state.label = AppLanguage.text("WorkBuddy 正在分析", "WorkBuddy is analyzing")
        case "phase.model_streaming", "phase.model_requesting", "phase.preparing", "phase.model_done":
            state.phase = event.phase == "phase.model_streaming" ? .review : .running
            state.label = state.phase == .review
                ? AppLanguage.text("WorkBuddy 正在分析", "WorkBuddy is analyzing")
                : AppLanguage.text("WorkBuddy 正在处理", "WorkBuddy is working")
            if event.phase != "phase.model_done" { state.toolActivity = nil }
        default:
            return
        }
        state.startedAt = state.startedAt ?? date
        states[event.id] = state
    }

    private func task(id: String, state: SessionState) -> CodexTaskItem {
        CodexTaskItem(
            id: id,
            provider: .workBuddy,
            title: "WorkBuddy",
            detail: state.label,
            project: "WorkBuddy",
            model: AppLanguage.text("未知模型", "Unknown model"),
            effort: AppLanguage.text("未提供", "Not provided"),
            totalTokens: nil,
            phase: state.phase,
            startedAt: state.startedAt,
            lastActivityAt: state.lastActivityAt,
            toolActivity: state.toolActivity,
            subtasks: [],
            queuedMessageCount: 0,
            isRealtimeActive: false
        )
    }

    private static func logDate(from line: String) -> Date? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestamp = object["timestamp"] as? String else { return nil }
        return ISO8601DateFormatter().date(from: timestamp)
    }
}
