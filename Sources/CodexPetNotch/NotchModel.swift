import AppKit
import Combine
import Foundation
import Network
import UniformTypeIdentifiers

extension Notification.Name {
    static let notchSizeChanged = Notification.Name("CodexPetNotch.sizeChanged")
}

enum CodexConnectionState: Equatable {
    case connected
    case disconnected
    case reconnecting
    case reconnected
}

enum UsageRemainingLevel {
    case normal
    case low
    case critical
    case unavailable
}

enum NotchPresentationMode: Equatable {
    case idle
    case compactIdle
    case collapsedCompletion
    case usage
    case drop
    case settings
    case collapsedTask
    case task
    case taskWithCompletion
    case taskList(Int)
    case inputRequired
    case waiting
    case completion
}

private struct PendingCompletion {
    let key: String
    let task: CodexTaskItem
    let message: String
    let eventDate: Date
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
    @Published var isTaskDisplayCollapsed = UserDefaults.standard.bool(forKey: "taskDisplayCollapsed")
    @Published var usesCompactBar = false
    @Published var connectionState: CodexConnectionState = .connected
    @Published var isHovered = false
    @Published var isDropTargeted = false
    @Published var latestDrop = AppLanguage.text("拖入文件、网址或文字", "Drop a file, URL, or text")
    @Published var pendingDropPrompt: String?
    @Published var clockTick = Date()
    @Published var activeTaskCount = 0
    @Published var activeTasks: [CodexTaskItem] = []
    @Published var todayTokens = 0
    @Published var todayTokensByModel: [String: Int] = [:]
    @Published var usageLimit: CodexUsageLimit?
    @Published var completionMessage: String?
    @Published var completedTask: CodexTaskItem?
    @Published var pendingCompletionCount = 0
    @Published var isCompletionStackCollapsed = false
    @Published var statusAnimationStartedAt = Date()

    private var activityTimer: Timer?
    private var clockTimer: Timer?
    private var hoverTask: Task<Void, Never>?
    private var pendingHoverValue: Bool?
    private var hoverSuppressedUntil = Date.distantPast
    private var dropExitTask: Task<Void, Never>?
    private var expandedForDrop = false
    private var pendingCompletions: [PendingCompletion] = []
    private var acknowledgedCompletionKeys: Set<String> = []
    private var petStackPeakSinceCompletion = 0
    private var reconnectTask: Task<Void, Never>?
    private var wasCodexConnected: Bool?
    private let networkMonitor = NWPathMonitor()
    private var networkAvailable = true
    private let taskMonitor = CodexTaskMonitor()
    private let codexStartedAt = NSRunningApplication
        .runningApplications(withBundleIdentifier: "com.openai.codex")
        .first?.launchDate ?? Date()
    var codexVersion: String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
              let bundle = Bundle(url: url) else { return AppLanguage.text("未知", "Unknown") }
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AppLanguage.text("未知", "Unknown")
    }
    private var lastActivity = CodexActivity(phase: .idle, label: AppLanguage.text("Codex 空闲", "Codex idle"), eventDate: .distantPast, startedAt: nil)

    init() {
        startNetworkMonitor()
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

    func refreshLanguage() {
        if pendingDropPrompt == nil {
            latestDrop = AppLanguage.text("拖入文件、网址或文字", "Drop a file, URL, or text")
        }
        objectWillChange.send()
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

    func toggleTaskDisplayCollapsed() {
        isTaskDisplayCollapsed.toggle()
        UserDefaults.standard.set(isTaskDisplayCollapsed, forKey: "taskDisplayCollapsed")
        if isTaskDisplayCollapsed { isTaskStatusPinned = false }
        NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
    }

    func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
    }

    func cancelPendingDrop() {
        dropExitTask?.cancel()
        pendingDropPrompt = nil
        latestDrop = AppLanguage.text("拖入文件、网址或文字", "Drop a file, URL, or text")
        isDropTargeted = false
        expandedForDrop = false
        isExpanded = false
        if activeTasks.isEmpty { state = .idle }
        NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
    }

    var taskRuntimeText: String? {
        guard let startedAt = lastActivity.startedAt,
              [.running, .review, .inputRequired, .waiting].contains(lastActivity.phase) else { return nil }
        let seconds = max(0, Int(clockTick.timeIntervalSince(startedAt)))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var codexUptimeText: String {
        let seconds = max(0, Int(clockTick.timeIntervalSince(codexStartedAt)))
        if seconds >= 3600 {
            return AppLanguage.text("运行 ", "Running ") + "\(seconds / 3600)h\((seconds % 3600) / 60)m"
        }
        return AppLanguage.text("运行 ", "Running ") + "\(seconds / 60)m"
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

    var todayModelUsageText: String? {
        let values = todayTokensByModel
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .prefix(2)
            .map { "\(shortModelName($0.key)) \(compactTokens($0.value))" }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private func shortModelName(_ value: String) -> String {
        value
            .replacingOccurrences(of: "gpt-", with: "")
            .replacingOccurrences(of: "-sol", with: " Sol")
            .replacingOccurrences(of: "-terra", with: " Terra")
    }

    private func compactTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.1fK", Double(tokens) / 1_000) }
        return "\(tokens)"
    }

    var remainingUsageText: String {
        guard let remainingUsagePercent else { return "--" }
        return "\(remainingUsagePercent)%"
    }

    var remainingUsageStatusText: String {
        switch remainingUsageLevel {
        case .low: AppLanguage.text("余量不多 \(remainingUsageText)", "Low · \(remainingUsageText) left")
        case .critical: AppLanguage.text("即将用尽 \(remainingUsageText)", "Critical · \(remainingUsageText) left")
        default: AppLanguage.text("剩余 \(remainingUsageText)", "\(remainingUsageText) left")
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
        guard let resetAt = usageLimit?.resetAt else { return AppLanguage.text("未提供", "Unavailable") }
        let seconds = max(0, Int(resetAt.timeIntervalSince(clockTick)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        if days > 0 { return AppLanguage.text("\(days)天\(hours)小时", "\(days)d \(hours)h") }
        let minutes = (seconds % 3_600) / 60
        return hours > 0
            ? AppLanguage.text("\(hours)小时\(minutes)分", "\(hours)h \(minutes)m")
            : AppLanguage.text("\(minutes)分钟", "\(minutes)m")
    }

    var planText: String {
        usageLimit?.planType?.capitalized ?? "Codex"
    }

    var visibleCompletionMessage: String? {
        guard state != .waiting, state != .failed, completedTask != nil else { return nil }
        return completionMessage
    }

    var hasCollapsedCompletion: Bool {
        isCompletionStackCollapsed && visibleCompletionMessage != nil
    }

    var waitingTask: CodexTaskItem? {
        activeTasks.first { $0.phase == .waiting }
    }

    var inputRequiredTask: CodexTaskItem? {
        activeTasks.first { $0.phase == .inputRequired }
    }

    var presentationMode: NotchPresentationMode {
        if isTaskDisplayCollapsed, primaryTask != nil { return .collapsedTask }
        if inputRequiredTask != nil { return .inputRequired }
        if waitingTask != nil { return .waiting }
        if isExpanded { return .drop }
        if isShowingSettings { return .settings }
        if isTaskStatusPinned, activeTasks.count > 1 { return .taskList(activeTasks.count) }
        if primaryTask != nil {
            return visibleCompletionMessage == nil || isCompletionStackCollapsed ? .task : .taskWithCompletion
        }
        if visibleCompletionMessage != nil {
            return isCompletionStackCollapsed ? .collapsedCompletion : .completion
        }
        if isHovered { return .usage }
        return usesCompactBar ? .compactIdle : .idle
    }

    var presentationSize: CGSize {
        switch presentationMode {
        case .idle: CGSize(width: 310, height: 38)
        case .compactIdle: CGSize(width: 270, height: 36)
        case .collapsedCompletion: CGSize(width: 322, height: 38)
        case .usage: CGSize(width: 450, height: 120)
        case .drop: CGSize(width: 450, height: 138)
        case .settings: CGSize(width: 450, height: 174)
        case .collapsedTask: CGSize(width: 424, height: 44)
        case .task: CGSize(width: 450, height: 86)
        case .taskWithCompletion: CGSize(width: 450, height: 122)
        case let .taskList(count): CGSize(width: 450, height: 80 + CGFloat(count * 40))
        case .inputRequired: CGSize(width: 450, height: 94)
        case .waiting: CGSize(width: 450, height: 94)
        case .completion: CGSize(width: 450, height: completedTask == nil ? 88 : 86)
        }
    }

    var primaryTask: CodexTaskItem? {
        let priority: [CodexActivity.Phase] = [.inputRequired, .waiting, .failed, .review, .running]
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
        hoverTask?.cancel()
        pendingHoverValue = nil
        hoverSuppressedUntil = Date().addingTimeInterval(0.8)
        isHovered = false
        if let completion = pendingCompletions.first(where: { $0.task.id == task.id }) {
            acknowledgedCompletionKeys.insert(completion.key)
            pendingCompletions.removeAll { $0.key == completion.key }
        }
        showNextCompletion()
        NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
        openTask(task)
    }

    func toggleCompletionStackCollapsed() {
        guard pendingCompletionCount > 0 else { return }
        isCompletionStackCollapsed.toggle()
        NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
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
                    let label = url?.lastPathComponent ?? AppLanguage.text("文件", "File")
                    let prompt = url.map { AppLanguage.text("请分析这个文件：\n\($0.path)", "Please analyze this file:\n\($0.path)") }
                        ?? AppLanguage.text("请分析我刚刚拖入的文件。", "Please analyze the file I just dropped.")
                    Task { @MainActor in self?.accept(label: label, prompt: prompt) }
                }
                return true
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, _ in
                    let url = item as? URL
                    let label = url?.host ?? AppLanguage.text("网页链接", "Web link")
                    let prompt = url.map { AppLanguage.text("请打开并分析这个网页：\n\($0.absoluteString)", "Please open and analyze this webpage:\n\($0.absoluteString)") }
                        ?? AppLanguage.text("请分析我刚刚拖入的网页链接。", "Please analyze the webpage I just dropped.")
                    Task { @MainActor in self?.accept(label: label, prompt: prompt) }
                }
                return true
            }
            if provider.canLoadObject(ofClass: NSString.self) {
                provider.loadObject(ofClass: NSString.self) { [weak self] value, _ in
                    let text = (value as? NSString).map(String.init) ?? ""
                    let excerpt = String(text.prefix(12_000))
                    let prompt = excerpt.isEmpty
                        ? AppLanguage.text("请分析我刚刚拖入的文字。", "Please analyze the text I just dropped.")
                        : AppLanguage.text("请分析下面的内容：\n\n\(excerpt)", "Please analyze the following content:\n\n\(excerpt)")
                    Task { @MainActor in
                        self?.accept(
                            label: text.isEmpty ? AppLanguage.text("文字", "Text") : String(text.prefix(32)),
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
        latestDrop = AppLanguage.text("已准备：\(label)", "Ready: \(label)")
        if !isExpanded { toggleExpanded() }
        state = .review
    }

    func startNewConversationFromDrop() {
        guard let prompt = pendingDropPrompt else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
        latestDrop = AppLanguage.text("正在 Codex 新建对话", "Creating a new Codex conversation")
        state = .jumping

        guard let url = CodexDeepLink.newThread(prompt: prompt),
              NSWorkspace.shared.open(url) else {
            latestDrop = AppLanguage.text("无法新建对话，请重试", "Could not create a conversation. Try again.")
            state = .failed
            return
        }
        pendingDropPrompt = nil
        latestDrop = AppLanguage.text("拖入文件、网址或文字", "Drop a file, URL, or text")
        isDropTargeted = false
        expandedForDrop = false
        isExpanded = false
        NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.3))
            guard let self else { return }
            if self.state == .jumping { self.state = .review }
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
        if todayTokensByModel != snapshot.todayTokensByModel {
            todayTokensByModel = snapshot.todayTokensByModel
        }
        if usageLimit != snapshot.usageLimit {
            usageLimit = snapshot.usageLimit
        }
        if let completedTask = snapshot.completedTask, activity.phase == .completed {
            enqueueCompletion(completedTask, message: activity.label, eventDate: activity.eventDate)
        }
        if let petStackItemCount = snapshot.petStackItemCount,
           let petStackUpdatedAt = snapshot.petStackUpdatedAt {
            reconcilePetCompletionStack(count: petStackItemCount, updatedAt: petStackUpdatedAt)
        }
        if let viewedThread = snapshot.viewedThread {
            acknowledgeViewedCompletion(viewedThread)
        }
        if taskLayoutChanged {
            NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
        }
        guard activity != lastActivity else { return }
        lastActivity = activity
        statusAnimationStartedAt = Date()
        switch activity.phase {
        case .idle: state = .idle
        case .running: state = .running
        case .review: state = .review
        case .inputRequired: state = .waiting
        case .waiting: state = .waiting
        case .completed:
            state = .jumping
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
        guard connected else {
            reconnectTask?.cancel()
            reconnectTask = nil
            connectionState = .disconnected
            return
        }
        guard networkAvailable else {
            reconnectTask?.cancel()
            reconnectTask = nil
            connectionState = .reconnecting
            return
        }
        guard let wasCodexConnected else {
            connectionState = .connected
            return
        }
        if connectionState == .reconnecting || !wasCodexConnected {
            connectionState = .reconnecting
            guard reconnectTask == nil else { return }
            let reconnectStartedAt = Date()
            reconnectTask = Task { @MainActor [weak self] in
                for _ in 0..<16 {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, let self,
                          !NSRunningApplication.runningApplications(
                            withBundleIdentifier: "com.openai.codex"
                          ).isEmpty,
                          self.networkAvailable else { return }
                    if self.taskMonitor.hasDesktopActivity(since: reconnectStartedAt) { break }
                }
                guard !Task.isCancelled, let self,
                      self.taskMonitor.hasDesktopActivity(since: reconnectStartedAt) else {
                    self?.reconnectTask = nil
                    return
                }
                self.connectionState = .reconnected
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self.connectionState = .connected
                self.reconnectTask = nil
            }
        }
    }

    private func startNetworkMonitor() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.networkAvailable = path.status == .satisfied
                self.refreshConnectionState()
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "codexnotch.network-monitor"))
    }

    private func enqueueCompletion(_ task: CodexTaskItem, message: String, eventDate: Date) {
        let key = "\(task.id)|\(eventDate.timeIntervalSince1970)"
        guard !acknowledgedCompletionKeys.contains(key),
              !pendingCompletions.contains(where: { $0.key == key }) else { return }
        if pendingCompletions.isEmpty {
            petStackPeakSinceCompletion = 0
        }
        pendingCompletions.append(PendingCompletion(key: key, task: task, message: message, eventDate: eventDate))
        showNextCompletion()
    }

    private func reconcilePetCompletionStack(count: Int, updatedAt: Date) {
        let eligible = pendingCompletions.filter { $0.eventDate <= updatedAt }
        guard !eligible.isEmpty else { return }
        let previousPeak = petStackPeakSinceCompletion
        petStackPeakSinceCompletion = max(previousPeak, count)
        let removalCount = min(eligible.count, max(0, previousPeak - count))
        guard removalCount > 0 else { return }
        let removed = Array(eligible.prefix(removalCount))
        let removedKeys = Set(removed.map(\.key))
        acknowledgedCompletionKeys.formUnion(removedKeys)
        pendingCompletions.removeAll { removedKeys.contains($0.key) }
        petStackPeakSinceCompletion = count
        showNextCompletion()
    }

    private func acknowledgeViewedCompletion(_ viewedThread: CodexViewedThread) {
        let viewed = pendingCompletions.filter {
            $0.task.id == viewedThread.id && $0.eventDate <= viewedThread.viewedAt
        }
        guard !viewed.isEmpty else { return }
        let viewedKeys = Set(viewed.map(\.key))
        acknowledgedCompletionKeys.formUnion(viewedKeys)
        pendingCompletions.removeAll { viewedKeys.contains($0.key) }
        showNextCompletion()
    }

    private func showNextCompletion() {
        pendingCompletionCount = pendingCompletions.count
        completedTask = pendingCompletions.first?.task
        completionMessage = pendingCompletions.first?.message
        if pendingCompletions.isEmpty {
            isCompletionStackCollapsed = false
            petStackPeakSinceCompletion = 0
        }
        NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
    }
}
