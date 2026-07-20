import Foundation

struct CodexActivity: Equatable {
    enum Phase: Equatable { case idle, running, review, waiting, completed, failed }
    let phase: Phase
    let label: String
    let eventDate: Date
    let startedAt: Date?
}

struct CodexStatusSnapshot {
    let primary: CodexActivity
    let activeCount: Int
    let tasks: [CodexTaskItem]
    let todayTokens: Int
    let usageLimit: CodexUsageLimit?
    let completedTask: CodexTaskItem?
    let viewedThread: CodexViewedThread?
    let petStackItemCount: Int?
    let petStackUpdatedAt: Date?
}

struct CodexViewedThread {
    let id: String
    let viewedAt: Date
}

struct CodexUsageLimit: Equatable {
    let usedPercent: Double
    let resetAt: Date?
    let planType: String?
}

struct CodexTaskItem: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let project: String
    let model: String
    let effort: String
    let totalTokens: Int?
    let phase: CodexActivity.Phase
    let startedAt: Date?
}

private struct MonitoredRollout {
    let activity: CodexActivity
    let task: CodexTaskItem
}

private struct ActivityCacheEntry {
    let modifiedAt: Date
    let rollout: MonitoredRollout?
}

private struct UsageCacheEntry {
    let modifiedAt: Date
    let tokens: Int
    let limit: CodexUsageLimit?
    let limitDate: Date
    let dayStart: Date
    let readOffset: UInt64
    let lastTotal: Int?
}

private struct ThreadMetadata {
    let title: String
    let description: String
}

final class CodexTaskMonitor: @unchecked Sendable {
    private let sessionsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true)
    private var cachedTodayTokens = 0
    private var cachedUsageLimit: CodexUsageLimit?
    private var tokenCacheDate = Date.distantPast
    private var pendingConfirmations: [String: MonitoredRollout] = [:]
    private var activityCache: [URL: ActivityCacheEntry] = [:]
    private var usageCache: [URL: UsageCacheEntry] = [:]
    private var cachedDesktopLogURL: URL?
    private var desktopLogDiscoveryDate = Date.distantPast
    private var desktopStateLogURL: URL?
    private var desktopLogOffset: UInt64 = 0
    private var cachedPetStackItemCount: Int?
    private var cachedPetStackUpdatedAt: Date?
    private var cachedViewedThread: CodexViewedThread?
    private var threadMetadata: [String: ThreadMetadata] = [:]

    func latestSnapshot() -> CodexStatusSnapshot {
        let desktopState = latestDesktopState()
        let observedRollouts = newestRollouts().compactMap(cachedActivity(for:))
        let rollouts = reconciledRollouts(observedRollouts)
        let usageStats = todayUsageStats()
        let activePhases: [CodexActivity.Phase] = [.running, .review, .waiting]
        let tasks = rollouts.filter { activePhases.contains($0.activity.phase) }.map(\.task)
        if let completion = rollouts.first(where: {
            $0.activity.phase == .completed && Date().timeIntervalSince($0.activity.eventDate) < 8
        }) {
            return CodexStatusSnapshot(primary: completion.activity, activeCount: tasks.count, tasks: tasks, todayTokens: usageStats.tokens, usageLimit: usageStats.limit, completedTask: completion.task, viewedThread: desktopState.viewedThread, petStackItemCount: desktopState.itemCount, petStackUpdatedAt: desktopState.updatedAt)
        }
        if let active = rollouts.first(where: { [.running, .review, .waiting, .failed].contains($0.activity.phase) }) {
            return CodexStatusSnapshot(primary: active.activity, activeCount: tasks.count, tasks: tasks, todayTokens: usageStats.tokens, usageLimit: usageStats.limit, completedTask: nil, viewedThread: desktopState.viewedThread, petStackItemCount: desktopState.itemCount, petStackUpdatedAt: desktopState.updatedAt)
        }
        let idle = CodexActivity(phase: .idle, label: AppLanguage.text("Codex 空闲", "Codex idle"), eventDate: .distantPast, startedAt: nil)
        return CodexStatusSnapshot(primary: idle, activeCount: 0, tasks: [], todayTokens: usageStats.tokens, usageLimit: usageStats.limit, completedTask: nil, viewedThread: desktopState.viewedThread, petStackItemCount: desktopState.itemCount, petStackUpdatedAt: desktopState.updatedAt)
    }

    func hasDesktopActivity(since date: Date) -> Bool {
        guard let url = desktopLogURL(),
              let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return false
        }
        return modifiedAt >= date
    }

    private func latestDesktopState() -> (viewedThread: CodexViewedThread?, itemCount: Int?, updatedAt: Date?) {
        guard let logURL = desktopLogURL(),
              let handle = try? FileHandle(forReadingFrom: logURL) else { return (nil, nil, nil) }
        defer { try? handle.close() }
        let length = (try? handle.seekToEnd()) ?? 0
        if desktopStateLogURL != logURL || length < desktopLogOffset {
            desktopStateLogURL = logURL
            desktopLogOffset = length > 8_000_000 ? length - 8_000_000 : 0
            cachedPetStackItemCount = nil
            cachedPetStackUpdatedAt = nil
            cachedViewedThread = nil
        }
        guard length > desktopLogOffset else {
            return (cachedViewedThread, cachedPetStackItemCount, cachedPetStackUpdatedAt)
        }
        try? handle.seek(toOffset: desktopLogOffset)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        desktopLogOffset = length
        for line in text.split(separator: "\n") {
            ingestThreadMetadata(from: String(line))
        }
        let petStackPattern = #"Native pet composition preparation sent .*activityStackItemCount=([0-9]+).*id=mascot-badge|id=mascot-badge.*activityStackItemCount=([0-9]+)"#
        let viewedPattern = #"thread_stream_view_activity_changed .*?(?:conversationId=([0-9a-f-]+).*?active=true|active=true.*?conversationId=([0-9a-f-]+)).*?rendererWindowFocused=true"#
        guard let petStackExpression = try? NSRegularExpression(pattern: petStackPattern),
              let viewedExpression = try? NSRegularExpression(pattern: viewedPattern) else {
            return (nil, nil, nil)
        }
        var foundPetStack = false
        var foundViewedThread = false
        for line in text.split(separator: "\n").reversed() {
            let value = String(line)
            let range = NSRange(value.startIndex..., in: value)
            if !foundPetStack,
               let match = petStackExpression.firstMatch(in: value, range: range),
               let countRange = Range(match.range(at: match.range(at: 1).location != NSNotFound ? 1 : 2), in: value),
               let count = Int(value[countRange]),
               let timestamp = value.split(separator: " ", maxSplits: 1).first,
               let updatedAt = Self.parseDate(String(timestamp)) {
                cachedPetStackItemCount = count
                cachedPetStackUpdatedAt = updatedAt
                foundPetStack = true
            }
            if !foundViewedThread,
               let match = viewedExpression.firstMatch(in: value, range: range),
               let idRange = Range(match.range(at: match.range(at: 1).location != NSNotFound ? 1 : 2), in: value),
               let timestamp = value.split(separator: " ", maxSplits: 1).first,
               let viewedAt = Self.parseDate(String(timestamp)) {
                cachedViewedThread = CodexViewedThread(id: String(value[idRange]), viewedAt: viewedAt)
                foundViewedThread = true
            }
            if foundPetStack, foundViewedThread { break }
        }
        return (cachedViewedThread, cachedPetStackItemCount, cachedPetStackUpdatedAt)
    }

    private func ingestThreadMetadata(from line: String) {
        guard line.contains("schemaVersion"), line.contains("threads"),
              let responseRange = line.range(of: " response="),
              let responseData = String(line[responseRange.upperBound...]).data(using: .utf8),
              let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let contentItems = response["contentItems"] as? [[String: Any]] else { return }
        for item in contentItems {
            guard let text = item["text"] as? String,
                  let data = text.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let threads = payload["threads"] as? [[String: Any]] else { continue }
            for thread in threads {
                guard let id = thread["id"] as? String,
                      let title = thread["title"] as? String else { continue }
                let description = (thread["description"] as? String)
                    ?? (thread["preview"] as? String)
                    ?? ""
                threadMetadata[id] = ThreadMetadata(title: title, description: description)
            }
        }
    }

    private func desktopLogURL() -> URL? {
        if Date().timeIntervalSince(desktopLogDiscoveryDate) < 30,
           let cachedDesktopLogURL,
           FileManager.default.fileExists(atPath: cachedDesktopLogURL.path) {
            return cachedDesktopLogURL
        }
        desktopLogDiscoveryDate = Date()
        let logsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/com.openai.codex", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: logsURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var newest: (url: URL, date: Date)?
        for case let url as URL in enumerator where url.pathExtension == "log" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let date = values?.contentModificationDate else { continue }
            if newest == nil || date > newest!.date { newest = (url, date) }
        }
        cachedDesktopLogURL = newest?.url
        return cachedDesktopLogURL
    }

    private func cachedActivity(for file: URL) -> MonitoredRollout? {
        guard let modifiedAt = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return nil
        }
        if let cached = activityCache[file], cached.modifiedAt == modifiedAt {
            return cached.rollout
        }
        let rollout = activity(for: file)
        activityCache[file] = ActivityCacheEntry(modifiedAt: modifiedAt, rollout: rollout)
        if activityCache.count > 24 {
            let retained = Set(newestRollouts(limit: 16))
            activityCache = activityCache.filter { retained.contains($0.key) }
        }
        return rollout
    }

    private func reconciledRollouts(_ observed: [MonitoredRollout]) -> [MonitoredRollout] {
        for rollout in observed {
            if rollout.activity.phase == .waiting {
                pendingConfirmations[rollout.task.id] = rollout
            } else {
                pendingConfirmations.removeValue(forKey: rollout.task.id)
            }
        }

        var bySession = Dictionary(uniqueKeysWithValues: pendingConfirmations.map { ($0.key, $0.value) })
        for rollout in observed where rollout.activity.phase != .waiting {
            if let current = bySession[rollout.task.id],
               current.activity.eventDate > rollout.activity.eventDate {
                continue
            }
            bySession[rollout.task.id] = rollout
        }
        return bySession.values.sorted { $0.activity.eventDate > $1.activity.eventDate }
    }

    private func todayUsageStats() -> (tokens: Int, limit: CodexUsageLimit?) {
        guard Date().timeIntervalSince(tokenCacheDate) >= 10 else {
            return (cachedTodayTokens, cachedUsageLimit)
        }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date())
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        var newestLimitDate = Date.distantPast
        var newestLimit: CodexUsageLimit?
        let recentURLs = newestRollouts(limit: 64)
        cachedTodayTokens = recentURLs.reduce(into: 0) { total, url in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let date = values.contentModificationDate,
                  calendar.isDateInToday(date) else { return }
            let entry: UsageCacheEntry
            if let cached = usageCache[url], cached.modifiedAt == date, cached.dayStart == dayStart {
                entry = cached
            } else {
                entry = readUsageEntry(
                    from: url,
                    modifiedAt: date,
                    dayStart: dayStart,
                    dayEnd: dayEnd,
                    previous: usageCache[url]
                )
                usageCache[url] = entry
            }
            total += entry.tokens
            if entry.limitDate > newestLimitDate {
                newestLimitDate = entry.limitDate
                newestLimit = entry.limit
            }
        }
        let retained = Set(recentURLs)
        usageCache = usageCache.filter { retained.contains($0.key) }
        cachedUsageLimit = newestLimit
        tokenCacheDate = Date()
        return (cachedTodayTokens, cachedUsageLimit)
    }

    private func readUsageEntry(
        from url: URL,
        modifiedAt: Date,
        dayStart: Date,
        dayEnd: Date,
        previous: UsageCacheEntry?
    ) -> UsageCacheEntry {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return UsageCacheEntry(modifiedAt: modifiedAt, tokens: 0, limit: nil, limitDate: .distantPast, dayStart: dayStart, readOffset: 0, lastTotal: nil)
        }
        defer { try? handle.close() }
        let length = (try? handle.seekToEnd()) ?? 0
        let canContinue = previous?.dayStart == dayStart && length >= (previous?.readOffset ?? 0)
        if !canContinue {
            return readInitialUsageEntryBackward(
                from: handle,
                length: length,
                modifiedAt: modifiedAt,
                dayStart: dayStart,
                dayEnd: dayEnd
            )
        }
        if let previous { try? handle.seek(toOffset: previous.readOffset) }
        var accumulator = CodexUsageAccumulator(
            dayStart: dayStart,
            dayEnd: dayEnd,
            dailyTokens: canContinue ? previous?.tokens ?? 0 : 0,
            latestLimit: canContinue ? previous?.limit : nil,
            latestLimitDate: canContinue ? previous?.limitDate ?? .distantPast : .distantPast,
            previousTotal: canContinue ? previous?.lastTotal : nil
        )
        enumerateLines(in: handle) { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let usage = info["total_token_usage"] as? [String: Any],
                  let tokenNumber = usage["total_tokens"] as? NSNumber else { return }
            let eventDate = (object["timestamp"] as? String).flatMap(Self.parseDate) ?? modifiedAt
            var limit: CodexUsageLimit?
            if let limits = payload["rate_limits"] as? [String: Any],
               let primary = limits["primary"] as? [String: Any],
               let used = (primary["used_percent"] as? NSNumber)?.doubleValue {
                limit = CodexUsageLimit(
                    usedPercent: used,
                    resetAt: (primary["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                    planType: limits["plan_type"] as? String
                )
            }
            accumulator.ingest(total: tokenNumber.intValue, at: eventDate, limit: limit)
        }
        return UsageCacheEntry(
            modifiedAt: modifiedAt,
            tokens: accumulator.dailyTokens,
            limit: accumulator.latestLimit,
            limitDate: accumulator.latestLimitDate,
            dayStart: dayStart,
            readOffset: length,
            lastTotal: accumulator.previousTotal
        )
    }

    private func readInitialUsageEntryBackward(
        from handle: FileHandle,
        length: UInt64,
        modifiedAt: Date,
        dayStart: Date,
        dayEnd: Date
    ) -> UsageCacheEntry {
        var offset = length
        var suffix = Data()
        var events: [(total: Int, date: Date, limit: CodexUsageLimit?)] = []
        var foundBaseline = false
        while offset > 0, !foundBaseline {
            let count = min(UInt64(262_144), offset)
            offset -= count
            try? handle.seek(toOffset: offset)
            guard let chunk = try? handle.read(upToCount: Int(count)) else { break }
            var combined = chunk
            combined.append(suffix)
            var lines = combined.split(separator: 0x0A, omittingEmptySubsequences: true)
            if offset > 0, !lines.isEmpty {
                suffix = Data(lines.removeFirst())
            } else {
                suffix.removeAll(keepingCapacity: true)
            }
            for line in lines.reversed() {
                guard let event = usageEvent(from: String(decoding: line, as: UTF8.self), fallbackDate: modifiedAt) else {
                    continue
                }
                events.append(event)
                if event.date < dayStart {
                    foundBaseline = true
                    break
                }
            }
        }

        var accumulator = CodexUsageAccumulator(dayStart: dayStart, dayEnd: dayEnd)
        for event in events.reversed() {
            accumulator.ingest(total: event.total, at: event.date, limit: event.limit)
        }
        return UsageCacheEntry(
            modifiedAt: modifiedAt,
            tokens: accumulator.dailyTokens,
            limit: accumulator.latestLimit,
            limitDate: accumulator.latestLimitDate,
            dayStart: dayStart,
            readOffset: length,
            lastTotal: accumulator.previousTotal
        )
    }

    private func enumerateLines(in handle: FileHandle, body: (String) -> Void) {
        var pending = Data()
        while let chunk = try? handle.read(upToCount: 262_144), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstRange(of: Data([0x0A])) {
                body(String(decoding: pending[..<newline.lowerBound], as: UTF8.self))
                pending.removeSubrange(..<newline.upperBound)
            }
        }
        if !pending.isEmpty { body(String(decoding: pending, as: UTF8.self)) }
    }

    private func usageEvent(
        from line: String,
        fallbackDate: Date
    ) -> (total: Int, date: Date, limit: CodexUsageLimit?)? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let usage = info["total_token_usage"] as? [String: Any],
              let tokenNumber = usage["total_tokens"] as? NSNumber else { return nil }
        let eventDate = (object["timestamp"] as? String).flatMap(Self.parseDate) ?? fallbackDate
        var limit: CodexUsageLimit?
        if let limits = payload["rate_limits"] as? [String: Any],
           let primary = limits["primary"] as? [String: Any],
           let used = (primary["used_percent"] as? NSNumber)?.doubleValue {
            limit = CodexUsageLimit(
                usedPercent: used,
                resetAt: (primary["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                planType: limits["plan_type"] as? String
            )
        }
        return (tokenNumber.intValue, eventDate, limit)
    }

    private func activity(for file: URL) -> MonitoredRollout? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attributes[.modificationDate] as? Date,
              let handle = try? FileHandle(forReadingFrom: file) else {
            return nil
        }
        defer { try? handle.close() }

        let length = (try? handle.seekToEnd()) ?? 0
        let sampleSize: UInt64 = 2_000_000
        try? handle.seek(toOffset: length > sampleSize ? length - sampleSize : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        var lastPhase: CodexActivity.Phase = .idle
        var lastLabel = AppLanguage.text("Codex 空闲", "Codex idle")
        var lastMessage: String?
        var lastEventDate = modified
        var completionDate: Date?
        var taskStartedAt: Date?
        var sessionID = Self.sessionID(from: file)
            ?? file.deletingPathExtension().lastPathComponent
        var project = "Codex"
        var model = AppLanguage.text("未知模型", "Unknown model")
        var effort = AppLanguage.text("未提供", "Unavailable")
        var totalTokens: Int?
        var lastUserMessage: String?

        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let type = (payload["type"] as? String) ?? (object["type"] as? String) else { continue }

            if let timestamp = object["timestamp"] as? String,
               let parsed = Self.parseDate(timestamp) {
                lastEventDate = parsed
            }

            switch type {
            case "session_meta":
                sessionID = payload["id"] as? String ?? sessionID
                if let cwd = payload["cwd"] as? String {
                    let directoryName = URL(fileURLWithPath: cwd).lastPathComponent
                    project = directoryName == "49labs" ? "CodexNotch" : directoryName
                }
            case "turn_context":
                model = payload["model"] as? String ?? model
                effort = (payload["effort"] as? String)
                    ?? (payload["reasoning_effort"] as? String)
                    ?? effort
            case "token_count":
                if let info = payload["info"] as? [String: Any],
                   let usage = info["total_token_usage"] as? [String: Any],
                   let total = usage["total_tokens"] as? NSNumber {
                    totalTokens = total.intValue
                }
            case "user_message":
                if let message = payload["message"] as? String, !message.isEmpty {
                    lastUserMessage = message
                }
            case "task_started":
                lastPhase = .running; lastLabel = AppLanguage.text("Codex 正在处理", "Codex is working"); taskStartedAt = lastEventDate
            case "task_complete":
                lastPhase = .completed
                completionDate = lastEventDate
                lastLabel = lastMessage.map(Self.summary) ?? AppLanguage.text("任务完成", "Task completed")
            case "agent_message":
                if let message = payload["message"] as? String, !message.isEmpty {
                    lastMessage = message
                }
            case "agent_reasoning":
                if lastPhase != .completed { lastPhase = .review; lastLabel = AppLanguage.text("Codex 正在分析", "Codex is analyzing") }
            case "elicitation_request", "request_user_input", "approval_request":
                lastPhase = .waiting; lastLabel = AppLanguage.text("等待你的确认", "Waiting for your confirmation")
            case "error", "turn_aborted":
                lastPhase = .failed; lastLabel = AppLanguage.text("任务遇到问题", "Task encountered a problem")
            default:
                break
            }
        }
        if lastPhase == .completed {
            lastLabel = lastMessage.map(Self.summary) ?? AppLanguage.text("任务完成", "Task completed")
        }
        let activity = CodexActivity(
            phase: lastPhase,
            label: lastLabel,
            eventDate: lastPhase == .completed ? completionDate ?? lastEventDate : lastEventDate,
            startedAt: taskStartedAt
        )
        let age = Date().timeIntervalSince(lastEventDate)
        if lastPhase == .waiting {
            guard age < 7 * 86_400 else { return nil }
        } else if [.running, .review, .failed].contains(lastPhase) {
            guard age < 6 * 3_600 else { return nil }
        }
        let task = CodexTaskItem(
            id: sessionID,
            title: threadMetadata[sessionID].map { Self.shortText($0.title, limit: 24) }
                ?? Self.taskTitle(lastUserMessage)
                ?? project,
            detail: lastMessage.map(Self.summary)
                ?? threadMetadata[sessionID].map { Self.shortText($0.description, limit: 38) }
                ?? project,
            project: project,
            model: model,
            effort: effort,
            totalTokens: totalTokens,
            phase: lastPhase,
            startedAt: taskStartedAt
        )
        return MonitoredRollout(activity: activity, task: task)
    }

    private static func sessionID(from file: URL) -> String? {
        let name = file.deletingPathExtension().lastPathComponent
        let pattern = #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#
        guard let range = name.range(of: pattern, options: .regularExpression) else { return nil }
        return String(name[range])
    }

    private static func taskTitle(_ message: String?) -> String? {
        guard var text = message?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let marker = text.range(of: "My request for Codex:") {
            text = String(text[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let line = text.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let line else { return nil }
        return line.count > 24 ? String(line.prefix(24)) + "…" : String(line)
    }

    private static func shortText(_ text: String, limit: Int) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count > limit ? String(clean.prefix(limit)) + "…" : clean
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func summary(_ message: String) -> String {
        let firstLine = message
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? AppLanguage.text("任务完成", "Task completed")
        let plain = firstLine.replacingOccurrences(of: "**", with: "")
        return plain.count > 34 ? String(plain.prefix(34)) + "…" : plain
    }

    private func newestRollouts(limit: Int = 8) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var rollouts: [(URL, Date)] = []
        for case let url as URL in enumerator where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let date = values?.contentModificationDate else { continue }
            rollouts.append((url, date))
        }
        return rollouts.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}
