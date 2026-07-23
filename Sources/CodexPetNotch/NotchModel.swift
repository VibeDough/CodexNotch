@preconcurrency import AppKit
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

enum UsageRemainingLevel: Equatable {
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
    case taskSearch
    case dailyReport
    case dailyReportReminder
    case lowUsageReminder
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

struct DropAction: Identifiable, Equatable {
    let id: String
    let title: String
    let icon: String
    let prompt: String
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
    @Published var isShowingTaskSearch = false
    @Published var isShowingDailyReport = false
    @Published var isDailyReportReminderVisible = false
    @Published var isLowUsageReminderVisible = false
    @Published var selectedDailyReportDate = Calendar.current.startOfDay(for: Date())
    @Published var taskSearchQuery = "" {
        didSet { applyTaskSearchFilter() }
    }
    @Published var taskSearchResults: [CodexTaskItem] = []
    @Published var isTaskStatusPinned = false
    @Published var isTaskDisplayCollapsed = UserDefaults.standard.bool(forKey: "taskDisplayCollapsed")
    @Published var usesCompactBar = false
    @Published var connectionState: CodexConnectionState = .connected
    @Published var isHovered = false
    @Published var isDropTargeted = false
    @Published var latestDrop = AppLanguage.text("拖入文件、网址或文字", "Drop a file, URL, or text")
    @Published var pendingDropPrompt: String?
    @Published var pendingDropActions: [DropAction] = []
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
    @Published var availableUpdate: AppUpdateInfo?
    @Published var isCheckingForUpdate = false
    @Published var hasCheckedForUpdate = false

    private var activityTimer: Timer?
    private var clockTimer: Timer?
    private var hoverTask: Task<Void, Never>?
    private var pendingHoverValue: Bool?
    private var hoverSuppressedUntil = Date.distantPast
    private var dropExitTask: Task<Void, Never>?
    private var expandedForDrop = false
    private var pendingCompletions: [PendingCompletion] = []
    private var recentTaskIndex: [CodexTaskItem] = []
    private var acknowledgedCompletionKeys: Set<String> = []
    private var petStackPeakSinceCompletion = 0
    private var reconnectTask: Task<Void, Never>?
    private var dailyReportReminderTask: Task<Void, Never>?
    private var lowUsageReminderTask: Task<Void, Never>?
    private var wasCodexConnected: Bool?
    private let networkMonitor = NWPathMonitor()
    private var networkAvailable = true
    private let taskMonitor = CodexTaskMonitor()
    private let dailyUsageHistory = DailyUsageHistory()
    private let codexStartedAt = NSRunningApplication
        .runningApplications(withBundleIdentifier: "com.openai.codex")
        .first?.launchDate ?? Date()
    private static let usageCachePrefix = "lastUsageLimit"
    private static let updateCachePrefix = "appUpdate"
    var codexVersion: String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
              let bundle = Bundle(url: url) else { return AppLanguage.text("未知", "Unknown") }
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AppLanguage.text("未知", "Unknown")
    }
    private var lastActivity = CodexActivity(phase: .idle, label: AppLanguage.text("Codex 空闲", "Codex idle"), eventDate: .distantPast, startedAt: nil)

    init() {
        usageLimit = Self.loadCachedUsageLimit()
        availableUpdate = Self.loadCachedUpdate()
        hasCheckedForUpdate = UserDefaults.standard.object(
            forKey: "\(Self.updateCachePrefix).lastCheckedAt"
        ) != nil
        startNetworkMonitor()
        startClock()
        startActivityMonitor()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.checkForUpdates()
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            self?.evaluateLowUsageReminder()
        }
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
        if isShowingSettings {
            isShowingTaskSearch = false
            isShowingDailyReport = false
        }
        NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
    }

    func showTaskSearch() {
        isShowingSettings = false
        isShowingDailyReport = false
        isShowingTaskSearch = true
        taskSearchQuery = ""
        recentTaskIndex = taskMonitor.recentTasks()
        applyTaskSearchFilter()
        NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
        NotificationCenter.default.post(name: .notchWantsKeyboardFocus, object: nil)
    }

    func showDailyReport() {
        isShowingSettings = false
        isShowingTaskSearch = false
        isDailyReportReminderVisible = false
        dailyReportReminderTask?.cancel()
        selectedDailyReportDate = Calendar.current.startOfDay(for: Date())
        isShowingDailyReport = true
        NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
    }

    func closeDailyReport() {
        guard isShowingDailyReport else { return }
        isShowingDailyReport = false
        NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
    }

    func dismissLowUsageReminder() {
        lowUsageReminderTask?.cancel()
        isLowUsageReminderVisible = false
        NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
    }

    func closeTaskSearch() {
        guard isShowingTaskSearch else { return }
        isShowingTaskSearch = false
        taskSearchQuery = ""
        NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
    }

    private func applyTaskSearchFilter() {
        let query = taskSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            taskSearchResults = Array(recentTaskIndex.prefix(8))
            return
        }
        taskSearchResults = recentTaskIndex.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.project.localizedCaseInsensitiveContains(query)
                || $0.detail.localizedCaseInsensitiveContains(query)
        }.prefix(8).map { $0 }
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
        let hadPresentedContent = isExpanded || isShowingTaskSearch || isShowingDailyReport
        guard hadPresentedContent else { return }
        isExpanded = false
        isShowingTaskSearch = false
        isShowingDailyReport = false
        taskSearchQuery = ""
        NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
    }

    func cancelPendingDrop() {
        dropExitTask?.cancel()
        pendingDropPrompt = nil
        pendingDropActions = []
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

    var dailyUsagePoints: [DailyUsagePoint] {
        dailyUsageHistory.lastSevenDays(todayTokens: todayTokens)
    }

    var dailyUsageHeatPoints: [DailyUsagePoint] {
        dailyUsageHistory.lastFourteenDays(todayTokens: todayTokens)
    }

    var activeUsageDays: Int {
        dailyUsageHeatPoints.filter { $0.tokens > 0 }.count
    }

    var usageStreakDays: Int {
        var streak = 0
        for point in dailyUsageHeatPoints.reversed() {
            guard point.tokens > 0 else {
                if streak == 0 && Calendar.current.isDateInToday(point.day) { continue }
                break
            }
            streak += 1
        }
        return streak
    }

    var dailyUsageAverage: Int {
        let previous = dailyUsagePoints.dropLast().map(\.tokens).filter { $0 > 0 }
        guard !previous.isEmpty else { return 0 }
        return previous.reduce(0, +) / previous.count
    }

    var dailyUsageEvaluation: String {
        dailyUsageEvaluation(tokens: selectedDailyReportTokens)
    }

    var selectedDailyReportTokens: Int {
        dailyUsagePoints.first {
            Calendar.current.isDate($0.day, inSameDayAs: selectedDailyReportDate)
        }?.tokens ?? 0
    }

    var selectedDailyReportTokenText: String {
        compactTokens(selectedDailyReportTokens)
    }

    var shouldCelebrateDailyReport: Bool {
        guard selectedDailyReportTokens > 0 else { return false }
        if dailyUsageAverage > 0 {
            return Double(selectedDailyReportTokens) / Double(dailyUsageAverage) >= 1.2
        }
        return selectedDailyReportTokens >= 75_000_000
    }

    var selectedDailyReportDateText: String {
        if Calendar.current.isDateInToday(selectedDailyReportDate) {
            return AppLanguage.text("今天", "Today")
        }
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.usesEnglish
            ? Locale(identifier: "en_US")
            : Locale(identifier: "zh_CN")
        formatter.dateFormat = AppLanguage.current.usesEnglish ? "MMM d" : "M月d日"
        return formatter.string(from: selectedDailyReportDate)
    }

    var selectedDailyUsageComparisonText: String {
        guard selectedDailyReportTokens > 0 else {
            return AppLanguage.text("这一天暂无本地用量数据", "No local usage data for this day")
        }
        let comparison = dailyUsagePoints
            .filter { !Calendar.current.isDate($0.day, inSameDayAs: selectedDailyReportDate) }
            .map(\.tokens)
            .filter { $0 > 0 }
        guard !comparison.isEmpty else {
            return AppLanguage.text("正在建立你的 7 日基线", "Building your 7-day baseline")
        }
        let average = comparison.reduce(0, +) / comparison.count
        let percent = Int((Double(selectedDailyReportTokens - average) / Double(average) * 100).rounded())
        if percent == 0 { return AppLanguage.text("与近 7 日均值持平", "Matches your 7-day average") }
        return percent > 0
            ? AppLanguage.text("比近 7 日均值高 \(percent)%", "\(percent)% above your 7-day average")
            : AppLanguage.text("比近 7 日均值低 \(abs(percent))%", "\(abs(percent))% below your 7-day average")
    }

    func selectDailyReportDate(_ date: Date) {
        selectedDailyReportDate = Calendar.current.startOfDay(for: date)
    }

    private func dailyUsageEvaluation(tokens: Int) -> String {
        guard tokens > 0 else { return AppLanguage.text("暂无数据", "No data") }
        let ratio: Double
        if dailyUsageAverage > 0 {
            ratio = Double(tokens) / Double(dailyUsageAverage)
        } else {
            ratio = Double(tokens) / 75_000_000
        }
        return switch ratio {
        case ..<0.5: AppLanguage.text("轻量使用", "Light use")
        case ..<1.0: AppLanguage.text("节奏稳定", "Steady pace")
        case ..<1.5: AppLanguage.text("高效推进", "Productive")
        case ..<2.2: AppLanguage.text("高强度", "High intensity")
        default: AppLanguage.text("超负荷", "Overdrive")
        }
    }

    var dailyUsageComparisonText: String {
        guard dailyUsageAverage > 0 else {
            return AppLanguage.text("正在建立你的 7 日基线", "Building your 7-day baseline")
        }
        let percent = Int((Double(todayTokens - dailyUsageAverage) / Double(dailyUsageAverage) * 100).rounded())
        if percent == 0 { return AppLanguage.text("与近 7 日均值持平", "Matches your 7-day average") }
        return percent > 0
            ? AppLanguage.text("比近 7 日均值高 \(percent)%", "\(percent)% above your 7-day average")
            : AppLanguage.text("比近 7 日均值低 \(abs(percent))%", "\(abs(percent))% below your 7-day average")
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
        if isLowUsageReminderVisible { return .lowUsageReminder }
        if isExpanded { return .drop }
        if isShowingTaskSearch { return .taskSearch }
        if isShowingSettings { return .settings }
        if isShowingDailyReport { return .dailyReport }
        if isDailyReportReminderVisible { return .dailyReportReminder }
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
        case .settings: CGSize(width: 450, height: 190)
        case .taskSearch: CGSize(width: 450, height: 268)
        case .dailyReport: CGSize(width: 450, height: 280)
        case .dailyReportReminder: CGSize(width: 450, height: 76)
        case .lowUsageReminder: CGSize(width: 390, height: 76)
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
                    guard let url else { return }
                    Task { @MainActor in self?.acceptFileURL(url) }
                }
                return true
            }
            if let imageType = provider.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: .image) == true
            }) {
                provider.loadDataRepresentation(forTypeIdentifier: imageType) { [weak self] data, _ in
                    guard let data,
                          let url = Self.writeTemporaryImage(data, typeIdentifier: imageType) else { return }
                    Task { @MainActor in self?.acceptFileURL(url) }
                }
                return true
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if provider.canLoadObject(ofClass: NSString.self) {
                    provider.loadObject(ofClass: NSString.self) { [weak self] value, _ in
                        guard let text = (value as? NSString).map(String.init),
                              let url = Self.webURL(from: text) else { return }
                        Task { @MainActor in self?.acceptWebURL(url) }
                    }
                } else {
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.url.identifier) { [weak self] data, _ in
                        guard let url = data.flatMap(Self.droppedURL(fromData:)) else { return }
                        Task { @MainActor in self?.acceptWebURL(url) }
                    }
                }
                return true
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.html.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.html.identifier, options: nil) { [weak self] item, _ in
                    let html = Self.droppedString(from: item)
                    let url = html.flatMap(Self.firstURL(inHTML:))
                    let label = url?.host ?? AppLanguage.text("网页链接", "Web link")
                    let prompt = url.map { AppLanguage.text("请打开并分析这个网页：\n\($0.absoluteString)", "Please open and analyze this webpage:\n\($0.absoluteString)") }
                        ?? AppLanguage.text("请分析我刚刚拖入的网页内容。", "Please analyze the webpage content I just dropped.")
                    Task { @MainActor in self?.accept(label: label, prompt: prompt) }
                }
                return true
            }
            if provider.canLoadObject(ofClass: NSString.self) {
                provider.loadObject(ofClass: NSString.self) { [weak self] value, _ in
                    let text = (value as? NSString).map(String.init) ?? ""
                    if let url = Self.webURL(from: text) {
                        let prompt = AppLanguage.text(
                            "请打开并分析这个网页：\n\(url.absoluteString)",
                            "Please open and analyze this webpage:\n\(url.absoluteString)"
                        )
                        Task { @MainActor in
                            self?.accept(label: url.host ?? AppLanguage.text("网页链接", "Web link"), prompt: prompt)
                        }
                        return
                    }
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

    nonisolated private static func droppedURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let url = item as? NSURL { return url as URL }
        return droppedString(from: item).flatMap(webURL(from:))
    }

    nonisolated private static func droppedString(from item: NSSecureCoding?) -> String? {
        if let string = item as? String { return string }
        if let string = item as? NSString { return string as String }
        if let data = item as? Data {
            return droppedURL(fromData: data)?.absoluteString
                ?? String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .utf16LittleEndian)
                ?? String(data: data, encoding: .utf16BigEndian)
        }
        return nil
    }

    nonisolated private static func webURL(from value: String) -> URL? {
        let decoded = value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\0", with: "")
        let pattern = #"https?://[^\s<>"']+"#
        let candidate: String
        if let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
           let match = expression.firstMatch(
                in: decoded,
                range: NSRange(decoded.startIndex..<decoded.endIndex, in: decoded)
           ),
           let range = Range(match.range, in: decoded) {
            candidate = String(decoded[range])
        } else {
            candidate = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    nonisolated private static func droppedURL(fromData data: Data) -> URL? {
        if let url = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: data) {
            return url as URL
        }
        let encodings: [String.Encoding] = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian]
        for encoding in encodings {
            if let value = String(data: data, encoding: encoding),
               let url = webURL(from: value) {
                return url
            }
        }
        if let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let url = firstWebURL(in: value) {
            return url
        }
        return nil
    }

    nonisolated private static func firstWebURL(in value: Any) -> URL? {
        if let string = value as? String { return webURL(from: string) }
        if let values = value as? [Any] {
            return values.lazy.compactMap(firstWebURL(in:)).first
        }
        if let values = value as? [String: Any] {
            return values.values.lazy.compactMap(firstWebURL(in:)).first
        }
        return nil
    }

    nonisolated private static func firstURL(inHTML html: String) -> URL? {
        guard let expression = try? NSRegularExpression(
            pattern: #"href\s*=\s*["'](https?://[^"']+)["']"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = expression.firstMatch(in: html, range: range),
              let urlRange = Range(match.range(at: 1), in: html) else { return nil }
        return webURL(from: String(html[urlRange]))
    }

    private func acceptWebURL(_ url: URL) {
        let address = url.absoluteString
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()

        if host == "github.com", path.contains("skill") {
            pendingDropActions = [
                DropAction(
                    id: "install-skill",
                    title: AppLanguage.text("安装 Skill", "Install Skill"),
                    icon: "square.and.arrow.down.fill",
                    prompt: AppLanguage.text(
                        "请使用 skill-installer 从这个 GitHub 地址安装 Codex Skill，并在安装前确认来源与安装目标：\n\(address)",
                        "Use skill-installer to install the Codex Skill from this GitHub URL. Confirm its source and install target first:\n\(address)"
                    )
                ),
                DropAction(
                    id: "analyze-skill",
                    title: AppLanguage.text("分析 Skill", "Analyze Skill"),
                    icon: "sparkles",
                    prompt: AppLanguage.text(
                        "请分析这个 Codex Skill 的用途、工作流程、适用场景与可以改进的地方：\n\(address)",
                        "Analyze this Codex Skill: its purpose, workflow, use cases, and possible improvements:\n\(address)"
                    )
                ),
                DropAction(
                    id: "inspect-skill",
                    title: AppLanguage.text("查看内容", "Inspect"),
                    icon: "doc.text.magnifyingglass",
                    prompt: AppLanguage.text(
                        "请阅读并说明这个 Codex Skill 的功能、触发方式、权限与潜在风险：\n\(address)",
                        "Review this Codex Skill and explain its purpose, triggers, permissions, and possible risks:\n\(address)"
                    )
                )
            ]
        } else if host == "github.com" {
            pendingDropActions = [
                DropAction(
                    id: "review-repository",
                    title: AppLanguage.text("分析仓库", "Review Repo"),
                    icon: "shippingbox.fill",
                    prompt: AppLanguage.text(
                        "请检查这个 GitHub 仓库的结构、核心功能、运行方式与值得借鉴的实现：\n\(address)",
                        "Review this GitHub repository: its structure, core features, setup, and useful implementation ideas:\n\(address)"
                    )
                ),
                DropAction(
                    id: "summarize-github",
                    title: AppLanguage.text("快速总结", "Summarize"),
                    icon: "text.alignleft",
                    prompt: AppLanguage.text(
                        "请快速总结这个 GitHub 页面，并列出最重要的信息：\n\(address)",
                        "Summarize this GitHub page and list the most important information:\n\(address)"
                    )
                )
            ]
        } else {
            pendingDropActions = [
                DropAction(
                    id: "summarize-web",
                    title: AppLanguage.text("总结网页", "Summarize"),
                    icon: "text.alignleft",
                    prompt: AppLanguage.text(
                        "请打开并总结这个网页，提取核心观点与重要信息：\n\(address)",
                        "Open and summarize this webpage, extracting its key ideas and important information:\n\(address)"
                    )
                ),
                DropAction(
                    id: "analyze-web",
                    title: AppLanguage.text("深入分析", "Analyze"),
                    icon: "sparkles",
                    prompt: AppLanguage.text(
                        "请打开并深入分析这个网页，指出关键结论、可信度与可执行建议：\n\(address)",
                        "Open and analyze this webpage in depth, including key conclusions, credibility, and actionable suggestions:\n\(address)"
                    )
                )
            ]
        }

        pendingDropPrompt = pendingDropActions.first?.prompt
        latestDrop = AppLanguage.text(
            "选择操作：\(url.host ?? "网页链接")",
            "Choose an action: \(url.host ?? "Web link")"
        )
        if !isExpanded { toggleExpanded() }
        state = .review
    }

    private func acceptFileURL(_ url: URL) {
        let path = url.path
        let type = UTType(filenameExtension: url.pathExtension)
        guard type?.conforms(to: .image) == true else {
            accept(
                label: url.lastPathComponent,
                prompt: AppLanguage.text(
                    "请分析这个文件：\n\(path)",
                    "Please analyze this file:\n\(path)"
                )
            )
            return
        }

        pendingDropActions = [
            DropAction(
                id: "edit-image",
                title: AppLanguage.text("修改图片", "Edit Image"),
                icon: "wand.and.stars",
                prompt: AppLanguage.text(
                    "请读取这张图片并先询问我具体想修改哪些内容，然后根据我的要求编辑图片：\n\(path)",
                    "Read this image, ask what I want to change, then edit it according to my instructions:\n\(path)"
                )
            ),
            DropAction(
                id: "reference-image",
                title: AppLanguage.text("仿照风格", "Match Style"),
                icon: "paintpalette.fill",
                prompt: AppLanguage.text(
                    "请分析这张图片的视觉风格、构图、色彩和材质，并基于这些特征设计一张相似风格但不直接复制的图片：\n\(path)",
                    "Analyze this image's visual style, composition, colors, and materials, then design a stylistically similar image without directly copying it:\n\(path)"
                )
            ),
            DropAction(
                id: "analyze-image",
                title: AppLanguage.text("分析图片", "Analyze"),
                icon: "photo.badge.magnifyingglass",
                prompt: AppLanguage.text(
                    "请分析这张图片的内容、构图、色彩、文字、视觉层级与可优化的地方：\n\(path)",
                    "Analyze this image's content, composition, colors, text, visual hierarchy, and possible improvements:\n\(path)"
                )
            )
        ]
        pendingDropPrompt = pendingDropActions.first?.prompt
        latestDrop = AppLanguage.text(
            "选择图片操作：\(url.lastPathComponent)",
            "Choose an image action: \(url.lastPathComponent)"
        )
        if !isExpanded { toggleExpanded() }
        state = .review
    }

    nonisolated private static func writeTemporaryImage(_ data: Data, typeIdentifier: String) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexNotch-Drops", isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )) != nil else { return nil }
        let extensionName = UTType(typeIdentifier)?.preferredFilenameExtension ?? "png"
        let url = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(extensionName)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func accept(label: String, prompt: String) {
        pendingDropPrompt = prompt
        pendingDropActions = [
            DropAction(
                id: "analyze",
                title: AppLanguage.text("交给 Codex", "Send to Codex"),
                icon: "plus.message.fill",
                prompt: prompt
            )
        ]
        latestDrop = AppLanguage.text("已准备：\(label)", "Ready: \(label)")
        if !isExpanded { toggleExpanded() }
        state = .review
    }

    func startNewConversationFromDrop(_ action: DropAction? = nil) {
        guard let prompt = action?.prompt ?? pendingDropPrompt else { return }
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
        pendingDropActions = []
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
                self?.evaluateDailyReportReminder()
            }
        }
    }

    private func evaluateDailyReportReminder() {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "dailyReportEnabled") == nil
            || defaults.bool(forKey: "dailyReportEnabled")
        guard enabled else { return }
        guard !isDailyReportReminderVisible,
              !isShowingDailyReport,
              activeTasks.isEmpty,
              visibleCompletionMessage == nil,
              todayTokens > 0 else { return }
        let now = Date()
        let components = Calendar.current.dateComponents([.hour, .minute], from: now)
        let reminderHour = defaults.object(forKey: "dailyReportHour") == nil
            ? 18 : defaults.integer(forKey: "dailyReportHour")
        let reminderMinute = defaults.object(forKey: "dailyReportMinute") == nil
            ? 30 : defaults.integer(forKey: "dailyReportMinute")
        guard (components.hour ?? 0) > reminderHour
                || ((components.hour ?? 0) == reminderHour
                    && (components.minute ?? 0) >= reminderMinute) else { return }
        let key = "dailyReportReminder.lastShown"
        if let lastShown = UserDefaults.standard.object(forKey: key) as? Date,
           Calendar.current.isDate(lastShown, inSameDayAs: now) {
            return
        }
        UserDefaults.standard.set(now, forKey: key)
        isDailyReportReminderVisible = true
        NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
        dailyReportReminderTask?.cancel()
        dailyReportReminderTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.isDailyReportReminderVisible else { return }
            self.isDailyReportReminderVisible = false
            NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
        }
    }

    private func evaluateLowUsageReminder() {
        guard !isLowUsageReminderVisible,
              let remainingUsagePercent,
              remainingUsagePercent < 50 else { return }
        let cycle: String
        if let resetAt = usageLimit?.resetAt {
            cycle = String(Int(resetAt.timeIntervalSince1970))
        } else {
            cycle = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
        }
        let key = "lowUsageReminder.lastCycle"
        guard UserDefaults.standard.string(forKey: key) != cycle else { return }
        UserDefaults.standard.set(cycle, forKey: key)
        isLowUsageReminderVisible = true
        NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
        lowUsageReminderTask?.cancel()
        lowUsageReminderTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, self.isLowUsageReminderVisible else { return }
            self.isLowUsageReminderVisible = false
            NotificationCenter.default.post(name: .notchSizeChanged, object: nil)
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
        if !snapshot.tasks.isEmpty,
           isShowingDailyReport || isDailyReportReminderVisible {
            isShowingDailyReport = false
            isDailyReportReminderVisible = false
            dailyReportReminderTask?.cancel()
            taskLayoutChanged = true
        }
        if snapshot.tasks.count < 2, isTaskStatusPinned {
            isTaskStatusPinned = false
            taskLayoutChanged = true
        }
        if todayTokens != snapshot.todayTokens {
            todayTokens = snapshot.todayTokens
            dailyUsageHistory.record(tokens: snapshot.todayTokens)
        }
        if todayTokensByModel != snapshot.todayTokensByModel {
            todayTokensByModel = snapshot.todayTokensByModel
        }
        if let latestUsageLimit = snapshot.usageLimit,
           usageLimit != latestUsageLimit {
            usageLimit = latestUsageLimit
            Self.saveCachedUsageLimit(latestUsageLimit)
            evaluateLowUsageReminder()
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

    private static func loadCachedUsageLimit() -> CodexUsageLimit? {
        let defaults = UserDefaults.standard
        let usedKey = "\(usageCachePrefix).usedPercent"
        guard defaults.object(forKey: usedKey) != nil else { return nil }
        let savedAt = defaults.object(forKey: "\(usageCachePrefix).savedAt") as? Date ?? .distantPast
        guard Date().timeIntervalSince(savedAt) < 14 * 86_400 else { return nil }
        let resetAt = defaults.object(forKey: "\(usageCachePrefix).resetAt") as? Date
        guard resetAt.map({ $0 > Date() }) ?? true else { return nil }
        return CodexUsageLimit(
            usedPercent: defaults.double(forKey: usedKey),
            resetAt: resetAt,
            planType: defaults.string(forKey: "\(usageCachePrefix).planType")
        )
    }

    private static func saveCachedUsageLimit(_ limit: CodexUsageLimit) {
        let defaults = UserDefaults.standard
        defaults.set(limit.usedPercent, forKey: "\(usageCachePrefix).usedPercent")
        defaults.set(limit.resetAt, forKey: "\(usageCachePrefix).resetAt")
        defaults.set(limit.planType, forKey: "\(usageCachePrefix).planType")
        defaults.set(Date(), forKey: "\(usageCachePrefix).savedAt")
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var updateStatusText: String {
        if let availableUpdate {
            return AppLanguage.text("可更新 \(availableUpdate.version)", "Update \(availableUpdate.version)")
        }
        if isCheckingForUpdate {
            return AppLanguage.text("检查中", "Checking")
        }
        if hasCheckedForUpdate {
            return AppLanguage.text("已是最新 \(appVersion)", "Up to date \(appVersion)")
        }
        return AppLanguage.text("检查更新", "Check")
    }

    func performUpdateAction() {
        if let availableUpdate {
            NSWorkspace.shared.open(availableUpdate.downloadURL)
        } else {
            checkForUpdates(force: true)
        }
    }

    func checkForUpdates(force: Bool = false) {
        guard !isCheckingForUpdate else { return }
        let defaults = UserDefaults.standard
        let lastCheckedAt = defaults.object(forKey: "\(Self.updateCachePrefix).lastCheckedAt") as? Date
        if !force,
           let lastCheckedAt,
           Date().timeIntervalSince(lastCheckedAt) < 24 * 3_600 {
            return
        }
        isCheckingForUpdate = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isCheckingForUpdate = false }
            do {
                let latest = try await AppUpdateChecker.latestRelease()
                defaults.set(Date(), forKey: "\(Self.updateCachePrefix).lastCheckedAt")
                self.hasCheckedForUpdate = true
                if AppVersion.isNewer(latest.version, than: self.appVersion) {
                    self.availableUpdate = latest
                    Self.saveCachedUpdate(latest)
                } else {
                    self.availableUpdate = nil
                    Self.clearCachedUpdate()
                }
            } catch {
                // A background update check should never interrupt the notch.
            }
        }
    }

    private static func loadCachedUpdate() -> AppUpdateInfo? {
        let defaults = UserDefaults.standard
        guard let version = defaults.string(forKey: "\(updateCachePrefix).version"),
              let releaseString = defaults.string(forKey: "\(updateCachePrefix).releaseURL"),
              let downloadString = defaults.string(forKey: "\(updateCachePrefix).downloadURL"),
              let releaseURL = URL(string: releaseString),
              let downloadURL = URL(string: downloadString),
              AppVersion.isNewer(
                version,
                than: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
              ) else { return nil }
        return AppUpdateInfo(version: version, releaseURL: releaseURL, downloadURL: downloadURL)
    }

    private static func saveCachedUpdate(_ update: AppUpdateInfo) {
        let defaults = UserDefaults.standard
        defaults.set(update.version, forKey: "\(updateCachePrefix).version")
        defaults.set(update.releaseURL.absoluteString, forKey: "\(updateCachePrefix).releaseURL")
        defaults.set(update.downloadURL.absoluteString, forKey: "\(updateCachePrefix).downloadURL")
    }

    private static func clearCachedUpdate() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "\(updateCachePrefix).version")
        defaults.removeObject(forKey: "\(updateCachePrefix).releaseURL")
        defaults.removeObject(forKey: "\(updateCachePrefix).downloadURL")
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
