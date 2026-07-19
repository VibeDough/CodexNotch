import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

extension Notification.Name {
    static let notchSizeChanged = Notification.Name("CodexPetNotch.sizeChanged")
}

enum CodexConnectionState {
    case connected
    case disconnected
    case reconnected
}

enum UsageRemainingLevel {
    case normal
    case low
    case critical
    case unavailable
}

@MainActor
final class NotchModel: ObservableObject {
    @Published var state: PetState = .idle {
        didSet {
            NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
        }
    }
    @Published var isExpanded = false
    @Published var isShowingSettings = false
    @Published var isTaskStatusPinned = false
    @Published var usesCompactBar = false
    @Published var connectionState: CodexConnectionState = .connected
    @Published var isHovered = false
    @Published var isDropTargeted = false
    @Published var latestDrop = "拖入文件、网址或文字"
    @Published var pendingDropPrompt: String?
    @Published var clockTick = Date()
    @Published var activeTaskCount = 0
    @Published var activeTasks: [CodexTaskItem] = []
    @Published var todayTokens = 0
    @Published var usageLimit: CodexUsageLimit?
    @Published var completionMessage: String?
    @Published var completedTask: CodexTaskItem?
    @Published var statusAnimationStartedAt = Date()

    private var activityTimer: Timer?
    private var clockTimer: Timer?
    private var hoverTask: Task<Void, Never>?
    private var pendingHoverValue: Bool?
    private var hoverSuppressedUntil = Date.distantPast
    private var dropExitTask: Task<Void, Never>?
    private var expandedForDrop = false
    private var completionDismissTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var wasCodexConnected: Bool?
    private let taskMonitor = CodexTaskMonitor()
    private let codexStartedAt = NSRunningApplication
        .runningApplications(withBundleIdentifier: "com.openai.codex")
        .first?.launchDate ?? Date()
    let codexVersion: String = {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
              let bundle = Bundle(url: url) else { return "未知" }
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    }()
    private var lastActivity = CodexActivity(phase: .idle, label: "Codex 空闲", eventDate: .distantPast, startedAt: nil)

    init() {
        startClock()
        startActivityMonitor()
    }

    func setHovered(_ hovered: Bool) {
        if hovered && Date() < hoverSuppressedUntil { return }
        if !hovered && isDropTargeted { return }
        if isHovered == hovered {
            if pendingHoverValue != nil {
                pendingHoverValue = nil
                hoverTask?.cancel()
            }
            return
        }
        guard pendingHoverValue != hovered else { return }
        pendingHoverValue = hovered
        hoverTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: hovered ? .milliseconds(35) : .milliseconds(90))
            guard !Task.isCancelled, let self, self.isHovered != hovered else { return }
            self.pendingHoverValue = nil
            self.isHovered = hovered
            NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
        }
    }

    func toggleExpanded() {
        isExpanded.toggle()
        NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
    }

    func toggleSettings() {
        isShowingSettings.toggle()
        NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
    }

    func toggleTaskStatusPinned() {
        guard activeTasks.count > 1 else {
            isTaskStatusPinned = false
            return
        }
        isTaskStatusPinned.toggle()
        NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
    }

    func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
    }

    var taskRuntimeText: String? {
        guard let startedAt = lastActivity.startedAt,
              [.running, .review, .waiting].contains(lastActivity.phase) else { return nil }
        let seconds = max(0, Int(clockTick.timeIntervalSince(startedAt)))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var codexUptimeText: String {
        let seconds = max(0, Int(clockTick.timeIntervalSince(codexStartedAt)))
        if seconds >= 3600 {
            return "运行 \(seconds / 3600)h\((seconds % 3600) / 60)m"
        }
        return "运行 \(seconds / 60)m"
    }

    var todayTokenText: String {
        let value: String
        if todayTokens >= 1_000_000 {
            value = String(format: "%.1fM", Double(todayTokens) / 1_000_000)
        } else if todayTokens >= 1_000 {
            value = String(format: "%.1fK", Double(todayTokens) / 1_000)
        } else {
            value = "\(todayTokens)"
        }
        return todayTokens >= 100_000 ? "\(value) 🔥" : value
    }

    var remainingUsageText: String {
        guard let remainingUsagePercent else { return "--" }
        return "\(remainingUsagePercent)%"
    }

    var remainingUsageStatusText: String {
        switch remainingUsageLevel {
        case .low: "余量不多 \(remainingUsageText)"
        case .critical: "即将用尽 \(remainingUsageText)"
        default: "剩余 \(remainingUsageText)"
        }
    }

    var remainingUsageLevel: UsageRemainingLevel {
        guard let remainingUsagePercent else { return .unavailable }
        if remainingUsagePercent < 20 { return .critical }
        if remainingUsagePercent < 50 { return .low }
        return .normal
    }

    private var remainingUsagePercent: Int? {
        guard let usageLimit else { return nil }
        return max(0, Int(floor(100 - usageLimit.usedPercent)))
    }

    var usageProgress: Double {
        guard let usageLimit else { return 0 }
        return max(0, min(1, (100 - usageLimit.usedPercent) / 100))
    }

    var resetCountdownText: String {
        guard let resetAt = usageLimit?.resetAt else { return "未提供" }
        let seconds = max(0, Int(resetAt.timeIntervalSince(clockTick)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        if days > 0 { return "\(days)天\(hours)小时" }
        let minutes = (seconds % 3_600) / 60
        return hours > 0 ? "\(hours)小时\(minutes)分" : "\(minutes)分钟"
    }

    var planText: String {
        usageLimit?.planType?.capitalized ?? "Codex"
    }

    var visibleCompletionMessage: String? {
        guard state != .waiting, state != .failed else { return nil }
        return completionMessage
    }

    var waitingTask: CodexTaskItem? {
        activeTasks.first { $0.phase == .waiting }
    }

    var primaryTask: CodexTaskItem? {
        let priority: [CodexActivity.Phase] = [.waiting, .failed, .review, .running]
        return priority.lazy.compactMap { phase in
            self.activeTasks.first { $0.phase == phase }
        }.first
    }

    func setDropTargeted(_ targeted: Bool) {
        dropExitTask?.cancel()
        if targeted {
            hoverTask?.cancel()
            if !isExpanded {
                expandedForDrop = true
                isExpanded = true
                NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
            }
            return
        }

        guard expandedForDrop else { return }
        dropExitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self, !self.isDropTargeted, self.expandedForDrop else { return }
            self.expandedForDrop = false
            self.collapse()
        }
    }

    func openCodex() {
        let workspace = NSWorkspace.shared
        let url = workspace.urlForApplication(withBundleIdentifier: "com.openai.codex")
            ?? URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    func openTask(_ task: CodexTaskItem) {
        if let url = URL(string: "codex://threads/\(task.id)"), NSWorkspace.shared.open(url) {
            return
        }
        openCodex()
    }

    func acknowledgeCompletedTask(_ task: CodexTaskItem) {
        completionDismissTask?.cancel()
        hoverTask?.cancel()
        pendingHoverValue = nil
        hoverSuppressedUntil = Date().addingTimeInterval(0.8)
        isHovered = false
        completionMessage = nil
        completedTask = nil
        NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
        openTask(task)
    }

    func receive(providers: [NSItemProvider]) -> Bool {
        dropExitTask?.cancel()
        expandedForDrop = false
        isDropTargeted = false
        state = .review
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                    let url: URL? = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    let label = url?.lastPathComponent ?? "文件"
                    let prompt = url.map { "请分析这个文件：\n\($0.path)" }
                        ?? "请分析我刚刚拖入的文件。"
                    Task { @MainActor in self?.accept(label: label, prompt: prompt) }
                }
                return true
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, _ in
                    let url = item as? URL
                    let label = url?.host ?? "网页链接"
                    let prompt = url.map { "请打开并分析这个网页：\n\($0.absoluteString)" }
                        ?? "请分析我刚刚拖入的网页链接。"
                    Task { @MainActor in self?.accept(label: label, prompt: prompt) }
                }
                return true
            }
            if provider.canLoadObject(ofClass: NSString.self) {
                provider.loadObject(ofClass: NSString.self) { [weak self] value, _ in
                    let text = (value as? NSString).map(String.init) ?? ""
                    let excerpt = String(text.prefix(12_000))
                    let prompt = excerpt.isEmpty ? "请分析我刚刚拖入的文字。" : "请分析下面的内容：\n\n\(excerpt)"
                    Task { @MainActor in
                        self?.accept(
                            label: text.isEmpty ? "文字" : String(text.prefix(32)),
                            prompt: prompt
                        )
                    }
                }
                return true
            }
        }
        return false
    }

    private func accept(label: String, prompt: String) {
        pendingDropPrompt = prompt
        latestDrop = "已准备：\(label)"
        if !isExpanded { toggleExpanded() }
        state = .review
    }

    func startNewConversationFromDrop() {
        guard let prompt = pendingDropPrompt else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
        latestDrop = "正在 Codex 新建对话"
        state = .jumping

        var components = URLComponents()
        components.scheme = "codex"
        components.host = "newThread"
        components.queryItems = [URLQueryItem(name: "prompt", value: prompt)]
        if let url = components.url, NSWorkspace.shared.open(url) == false {
            openCodex()
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.3))
            guard let self else { return }
            if self.state == .jumping { self.state = .review }
            self.pendingDropPrompt = nil
            self.latestDrop = "拖入文件、网址或文字"
            self.collapse()
        }
    }

    private func startClock() {
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.clockTick = Date()
            }
        }
    }

    private func startActivityMonitor() {
        refreshActivity()
        activityTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshActivity() }
        }
    }

    private func refreshActivity() {
        refreshConnectionState()
        let snapshot = taskMonitor.latestSnapshot()
        let activity = snapshot.primary
        var taskLayoutChanged = false
        if activeTaskCount != snapshot.activeCount {
            activeTaskCount = snapshot.activeCount
            taskLayoutChanged = true
        }
        if activeTasks != snapshot.tasks {
            activeTasks = snapshot.tasks
            taskLayoutChanged = true
        }
        if snapshot.tasks.count < 2, isTaskStatusPinned {
            isTaskStatusPinned = false
            taskLayoutChanged = true
        }
        if todayTokens != snapshot.todayTokens {
            todayTokens = snapshot.todayTokens
        }
        if usageLimit != snapshot.usageLimit {
            usageLimit = snapshot.usageLimit
        }
        if snapshot.completedTask != nil {
            completedTask = snapshot.completedTask
        }
        if taskLayoutChanged {
            NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
        }
        guard activity != lastActivity else { return }
        let isNewCompletion = activity.phase == .completed && activity.eventDate != lastActivity.eventDate
        lastActivity = activity
        latestDrop = activity.label
        statusAnimationStartedAt = Date()
        switch activity.phase {
        case .idle: state = .idle
        case .running: state = .running
        case .review: state = .review
        case .waiting: state = .waiting
        case .completed:
            state = .jumping
            if isNewCompletion { showCompletion(activity.label) }
        case .failed: state = .failed
        }
    }

    func setCompactBar(_ compact: Bool) {
        guard usesCompactBar != compact else { return }
        usesCompactBar = compact
        NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
    }

    private func refreshConnectionState() {
        let connected = !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.codex"
        ).isEmpty
        defer { wasCodexConnected = connected }
        guard let wasCodexConnected else {
            connectionState = connected ? .connected : .disconnected
            return
        }
        if !connected {
            reconnectTask?.cancel()
            connectionState = .disconnected
        } else if !wasCodexConnected {
            connectionState = .reconnected
            reconnectTask?.cancel()
            reconnectTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.connectionState = .connected
            }
        }
    }

    private func showCompletion(_ message: String) {
        completionDismissTask?.cancel()
        completionMessage = message
        NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
    }
}
