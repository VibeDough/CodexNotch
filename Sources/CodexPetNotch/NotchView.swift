import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NotchView: View {
    @ObservedObject var model: NotchModel
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue
    @FocusState private var taskSearchFocused: Bool

    private func text(_ chinese: String, _ english: String) -> String {
        (AppLanguage(rawValue: appLanguage) ?? .system).usesEnglish ? english : chinese
    }

    private var showsTaskDetails: Bool {
        model.isTaskStatusPinned && model.activeTasks.count > 1
    }

    private var showsUsageDetails: Bool {
        model.isHovered && model.activeTasks.isEmpty && !model.hasCollapsedCompletion
    }

    private var showsDetails: Bool {
        showsTaskDetails || showsUsageDetails || model.isShowingSettings
            || model.isShowingTaskSearch || model.isShowingDailyReport
            || model.isDailyReportReminderVisible || model.isLowUsageReminderVisible
    }

    var body: some View {
        VStack(spacing: 0) {
            collapsedBar

            if model.isTaskDisplayCollapsed, model.primaryTask != nil {
                EmptyView()
            } else if let task = model.inputRequiredTask {
                inputRequiredCard(task)
            } else if let task = model.waitingTask {
                confirmationCard(task)
            } else if model.isLowUsageReminderVisible {
                lowUsageReminder
            } else if model.isExpanded {
                EmptyView()
            } else if model.isShowingTaskSearch {
                taskSearchContent
            } else if model.isShowingSettings {
                settingsContent
            } else if model.isShowingDailyReport {
                dailyReportContent
            } else if model.isDailyReportReminderVisible {
                dailyReportReminder
            } else if showsTaskDetails {
                taskDetails
            } else if let task = model.primaryTask {
                VStack(spacing: 0) {
                    persistentTaskStatus(task)
                    if !model.isCompletionStackCollapsed,
                       let completedTask = model.completedTask,
                       model.visibleCompletionMessage != nil {
                        compactCompletedTaskStatus(completedTask)
                    }
                }
            } else if !model.isCompletionStackCollapsed,
                      let message = model.visibleCompletionMessage,
                      let task = model.completedTask {
                completedTaskStatus(message: message, task: task)
            } else if model.activeTasks.isEmpty,
                      model.visibleCompletionMessage == nil,
                      !model.isExpanded {
                tokenDetails
                    .opacity(showsUsageDetails ? 1 : 0)
                    .transition(.opacity)
            }

            if model.isExpanded {
                expandedContent
                    .background(.black)
                    .clipShape(.rect(bottomLeadingRadius: 18, bottomTrailingRadius: 18))
                    .transition(.scale(scale: 0.92, anchor: .top).combined(with: .opacity))
            }
        }
        .frame(width: visualSize.width, height: visualSize.height, alignment: .top)
        .clipped()
        .ignoresSafeArea(.all)
        .background {
            if model.usesCompactBar && !showsDetails && !model.isExpanded {
                Capsule().fill(.black)
            } else {
                IslandShape(
                    shoulder: 0,
                    bottomRadius: showsDetails || model.primaryTask != nil
                        && !model.isTaskDisplayCollapsed
                        || (model.visibleCompletionMessage != nil && !model.isCompletionStackCollapsed)
                        || model.inputRequiredTask != nil || model.waitingTask != nil || model.isExpanded ? 18 : 12
                )
                .fill(.black)
            }
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.black)
                .frame(height: 12)
                .allowsHitTesting(false)
        }
        .overlay { edgeStatusGlow }
        .animation(.smooth(duration: 0.22), value: model.presentationMode)
        .animation(.smooth(duration: 0.22), value: model.completedTask?.id)
        .animation(.smooth(duration: 0.22), value: model.connectionState)
        .animation(.smooth(duration: 0.22), value: model.isLowUsageReminderVisible)
        .onChange(of: appLanguage) { _, _ in model.refreshLanguage() }
        .onChange(of: model.isShowingTaskSearch) { _, showing in
            guard showing else {
                taskSearchFocused = false
                return
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                taskSearchFocused = true
            }
        }
        .onChange(of: model.isDropTargeted) { _, targeted in
            model.setDropTargeted(targeted)
        }
        .onDrop(of: [UTType.fileURL, UTType.image, UTType.url, UTType.html, UTType.utf8PlainText], isTargeted: $model.isDropTargeted) {
            model.receive(providers: $0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var visualSize: CGSize {
        model.presentationSize
    }

    private var collapsedBar: some View {
        HStack(spacing: 7) {
            Button(action: model.openCodex) {
                HStack(spacing: 5) {
                    if model.connectionState == .disconnected {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.red)
                            .frame(width: 20, height: 20)
                            .offset(x: 8)
                            .help(text("连接已断开", "Disconnected"))
                    } else if model.connectionState == .reconnecting {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.red)
                            .frame(width: 20, height: 20)
                            .offset(x: 8)
                            .help(text("正在重连", "Reconnecting"))
                    } else if model.connectionState == .reconnected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.cyan)
                            .frame(width: 20, height: 20)
                            .offset(x: 8)
                            .help(text("已重连", "Reconnected"))
                    } else {
                        Text(model.remainingUsageText)
                            .font(.system(size: 13, weight: .black, design: .rounded))
                    }
                }
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(collapsedUsageColor)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 94, height: 30, alignment: .leading)
                .contentShape(Rectangle().inset(by: -7))
            }
            .buttonStyle(.plain)
            .help(text("打开 Codex", "Open Codex"))

            Spacer(minLength: model.isTaskDisplayCollapsed && model.primaryTask != nil ? 220 : 92)

            ZStack(alignment: .trailing) {
                Group {
                    if model.isTaskDisplayCollapsed, model.primaryTask != nil {
                        Button(action: model.toggleTaskDisplayCollapsed) {
                            taskStatus
                        }
                        .buttonStyle(.plain)
                        .help(text("展开任务详情", "Show task details"))
                    } else if model.hasCollapsedCompletion {
                        Button(action: model.toggleCompletionStackCollapsed) {
                            completionCountBadge
                        }
                        .buttonStyle(.plain)
                        .help(text("展开已完成任务", "Show completed tasks"))
                    } else if model.activeTasks.count > 1 {
                        Button { model.toggleTaskStatusPinned() } label: { taskStatus }
                            .buttonStyle(.plain)
                            .help(model.isTaskStatusPinned
                                ? text("取消常驻任务", "Unpin task list")
                                : text("常驻显示任务", "Pin task list"))
                    } else if let task = model.primaryTask {
                        Button { model.openTask(task) } label: { taskStatus }
                            .buttonStyle(.plain)
                            .help(text("打开当前任务", "Open current task"))
                    } else {
                        taskStatus
                    }
                }
                .opacity(model.isHovered && !model.hasCollapsedCompletion && !model.isTaskDisplayCollapsed ? 0 : 1)

                if model.isHovered && !model.hasCollapsedCompletion && !model.isTaskDisplayCollapsed {
                    HStack(spacing: 6) {
                        Button(action: model.showTaskSearch) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(.white.opacity(0.1), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help(text("搜索最近任务", "Search recent tasks"))

                        Button(action: model.toggleSettings) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: model.isShowingSettings ? 10.5 : 12, weight: .semibold))
                                .foregroundStyle(model.isShowingSettings ? .black : .white)
                                .frame(width: 28, height: 28)
                                .background {
                                    Circle()
                                        .fill(model.isShowingSettings ? .white : .white.opacity(0.1))
                                        .frame(width: model.isShowingSettings ? 20 : 28,
                                               height: model.isShowingSettings ? 20 : 28)
                                }
                                .overlay(alignment: .topTrailing) {
                                    if model.availableUpdate != nil {
                                        Circle()
                                            .fill(.cyan)
                                            .frame(width: 6, height: 6)
                                            .offset(x: 1, y: -1)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .help(text("设置", "Settings"))

                        Button {
                            NSApplication.shared.terminate(nil)
                        } label: {
                            Image(systemName: "power")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(.white.opacity(0.09), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help(text("退出", "Quit"))
                    }
                    .frame(width: 96, height: 28)
                    .transition(.scale(scale: 0.86, anchor: .trailing).combined(with: .opacity))
                }
            }
            .frame(
                width: model.isTaskDisplayCollapsed && model.primaryTask != nil
                    ? 76 : (model.isHovered ? 100 : 68),
                height: 28
            )
            .animation(.easeOut(duration: 0.14), value: model.isHovered)
        }
        .padding(.horizontal, 10)
        .frame(height: collapsedBarHeight)
        .contentShape(Rectangle())
        .overlay {
            IslandShape(shoulder: 5, bottomRadius: 12)
                .stroke(model.isDropTargeted ? Color.white.opacity(0.75) : .clear, lineWidth: 1)
        }
        .contextMenu {
            Button(text("退出", "Quit")) { NSApplication.shared.terminate(nil) }
        }
    }

    private var collapsedBarHeight: CGFloat {
        let isIdle = model.activeTasks.isEmpty
            && (model.visibleCompletionMessage == nil || model.hasCollapsedCompletion)
            && model.waitingTask == nil
            && !model.isExpanded
            && !model.isShowingSettings
            && !model.isHovered
        return model.usesCompactBar ? 36 : (isIdle ? 38 : 44)
    }

    private var collapsedUsageColor: Color {
        guard model.connectionState == .connected, !model.isHovered else {
            return .white.opacity(0.9)
        }
        return switch model.remainingUsageLevel {
        case .low: .orange
        case .critical: .red
        default: .white.opacity(0.9)
        }
    }

    @ViewBuilder
    private var edgeStatusGlow: some View {
        if model.connectionState == .disconnected || model.connectionState == .reconnecting {
            EdgeGlowBorder(compact: model.usesCompactBar, expanded: showsDetails || (model.primaryTask != nil && !model.isTaskDisplayCollapsed), animated: false, color: .red)
        } else if model.activeTaskCount > 0 || model.connectionState == .reconnected {
            EdgeGlowBorder(compact: model.usesCompactBar, expanded: showsDetails || (model.primaryTask != nil && !model.isTaskDisplayCollapsed), animated: true, color: .cyan)
        }
    }

    private var taskStatus: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(currentStatusColor)
                .frame(width: 7, height: 7)
            Text(currentStatusText)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.68))
            Text("\(model.activeTaskCount)")
                .font(.system(size: 13, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .offset(y: -1.5)
            if model.isTaskDisplayCollapsed, model.primaryTask != nil {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .black))
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .frame(width: model.isTaskDisplayCollapsed && model.primaryTask != nil ? 76 : 68, height: 28, alignment: .trailing)
        .accessibilityLabel(text("正在执行 \(model.activeTaskCount) 个任务", "\(model.activeTaskCount) active tasks"))
    }

    private var completionCountBadge: some View {
        HStack(spacing: 5) {
            CompletionCheckAnimation(
                size: 13,
                lineWidth: 1.8,
                fill: .clear,
                stroke: Color(red: 0.06, green: 0.38, blue: 0.17),
                check: Color(red: 0.06, green: 0.38, blue: 0.17)
            )
            .id(model.completedTask?.id ?? "\(model.pendingCompletionCount)")
            Text("\(model.pendingCompletionCount)")
                .font(.system(size: 12, weight: .black, design: .rounded))
                .contentTransition(.numericText())
        }
        .foregroundStyle(Color(red: 0.06, green: 0.38, blue: 0.17))
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Color(red: 0.46, green: 0.9, blue: 0.59), in: Capsule())
        .offset(y: 2)
        .frame(width: 68, height: 28, alignment: .trailing)
        .accessibilityLabel(text("\(model.pendingCompletionCount) 个待查看任务", "\(model.pendingCompletionCount) completed tasks to review"))
    }

    private var currentStatusText: String {
        if model.connectionState == .reconnecting { return text("正在重连", "Retry") }
        guard model.activeTaskCount > 0 else { return text("空闲", "Idle") }
        if hasStaleActiveTask { return text("较久", "Quiet") }
        return switch currentActivePhase {
        case .inputRequired: text("需输入", "Input")
        case .waiting: text("等待", "Wait")
        case .failed: text("异常", "Issue")
        case .review: text("分析", "Review")
        default: text("运行", "Run")
        }
    }

    private var currentStatusColor: Color {
        if model.connectionState == .disconnected || model.connectionState == .reconnecting { return .red }
        if model.connectionState == .reconnected { return .cyan }
        guard model.activeTaskCount > 0 else { return .white.opacity(0.3) }
        if hasStaleActiveTask { return .orange }
        return switch currentActivePhase {
        case .inputRequired: .orange
        case .waiting: .orange
        case .failed: .red
        default: .green
        }
    }

    private var currentActivePhase: CodexActivity.Phase? {
        let priority: [CodexActivity.Phase] = [.inputRequired, .waiting, .failed, .review, .running]
        return priority.first { phase in model.activeTasks.contains { $0.phase == phase } }
    }

    private var hasStaleActiveTask: Bool {
        model.activeTasks.contains(where: isTaskStale)
    }

    private var taskDetails: some View {
        VStack(spacing: 0) {
            ForEach(model.activeTasks) { task in
                Button { model.openTask(task) } label: {
                    HStack(spacing: 9) {
                        Circle()
                            .fill(statusColor(task))
                            .frame(width: 6, height: 6)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(task.detail)
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(modelName(task.model))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.78))
                            Text(taskUsageLine(task))
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .frame(height: 40)
                }
                .buttonStyle(.plain)
                .help(text("返回 Codex 对话", "Return to Codex conversation"))

                if task.id != model.activeTasks.last?.id {
                    Divider().overlay(.white.opacity(0.08))
                }
            }

            if model.activeTasks.count > 1 {
                Button { model.toggleTaskStatusPinned() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 8.5, weight: .black))
                        Text(text("收起任务", "Collapse tasks"))
                            .font(.system(size: 9.5, weight: .bold))
                    }
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(text("收起任务列表", "Collapse task list"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var tokenDetails: some View {
        VStack(spacing: 9) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(text("今日消耗", "Today"))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                    Text(model.todayTokenText)
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    if let breakdown = model.todayModelUsageText {
                        Text(breakdown)
                            .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.42))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 10)
                Button(action: model.showDailyReport) {
                    VStack(spacing: 4) {
                        HStack(spacing: 5) {
                            Image(systemName: "flame.fill")
                                .foregroundStyle(.orange)
                            Text(model.activeUsageDays == 0
                                ? text("正在建立使用基线", "Building your baseline")
                                : "\(text("连续", "Streak")) \(model.usageStreakDays) \(text("天", "days")) · \(model.todayUsageEvaluation)")
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                        }
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.72))

                        HStack(spacing: 6) {
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(.white.opacity(0.1))
                                    .overlay(alignment: .leading) {
                                        Capsule()
                                            .fill(.linearGradient(
                                                colors: [.orange, .pink, .purple],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            ))
                                            .frame(
                                                width: proxy.size.width
                                                    * CGFloat(model.activeUsageDays) / 14
                                            )
                                    }
                            }
                            .frame(height: 3)
                            Text("\(model.activeUsageDays)/14")
                                .font(.system(size: 7.5, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.38))
                        }
                    }
                    .frame(width: 158, height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .allowsHitTesting(showsUsageDetails)
                .accessibilityLabel(text("查看今日报告", "View today's report"))
                .help(text("查看今日报告", "View today's report"))
                Spacer(minLength: 10)
                Text(model.planText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }

            HStack(spacing: 8) {
                Label(model.remainingUsageStatusText, systemImage: "gauge.with.dots.needle.50percent")
                    .foregroundStyle(expandedUsageColor)
                    .lineLimit(1)
                Label(text("重置 \(model.resetCountdownText)", "Resets in \(model.resetCountdownText)"), systemImage: "clock")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
                Spacer(minLength: 0)
                Text(text("版本 \(model.codexVersion)", "Version \(model.codexVersion)"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.56))
        }
        .padding(.horizontal, 13)
        .padding(.bottom, 11)
    }

    private var dailyReportReminder: some View {
        Button(action: model.showDailyReport) {
            HStack(spacing: 9) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(text("今日", "Today")) \(model.todayTokenText) · \(model.dailyUsageEvaluation)")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                    Text(model.dailyUsageComparisonText)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.42))
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var lowUsageReminder: some View {
        HStack(spacing: 10) {
            Text("!")
                .font(.system(size: 15, weight: .black, design: .rounded))
                .foregroundStyle(model.remainingUsageLevel == .critical ? .red : .orange)

            LowUsageAnimatedText(
                value: model.remainingUsageLevel == .critical
                    ? text("额度即将用尽 \(model.remainingUsageText)", "Usage almost exhausted \(model.remainingUsageText)")
                    : text("余量不多 \(model.remainingUsageText)", "Usage running low \(model.remainingUsageText)"),
                color: model.remainingUsageLevel == .critical ? .red : .orange
            )

            Spacer()

            Button(action: model.dismissLowUsageReminder) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 24, height: 24)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help(text("关闭", "Dismiss"))
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
    }

    private var dailyReportContent: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(text("Token 能量轨迹", "Token energy"))
                        .font(.system(size: 12, weight: .bold))
                    Text("\(model.selectedDailyReportDateText) · \(model.selectedDailyReportTokenText) · \(model.dailyUsageEvaluation)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.48))
                }
                Spacer()
                Button(action: model.closeDailyReport) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
            }

            DailyUsageHeatGrid(
                points: model.dailyUsageHeatPoints,
                selectedDate: model.selectedDailyReportDate,
                onSelect: model.selectDailyReportDate
            )
            .frame(height: 58)

            HStack(spacing: 9) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(.orange)
                Text(text("连续 \(model.usageStreakDays) 天", "\(model.usageStreakDays)-day streak"))
                    .fontWeight(.bold)
                Capsule()
                    .fill(.white.opacity(0.1))
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(.linearGradient(
                                    colors: [.orange, .pink, .purple],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ))
                                .frame(width: proxy.size.width * CGFloat(model.activeUsageDays) / 14)
                        }
                    }
                Text("\(model.activeUsageDays)/14")
                    .foregroundStyle(.white.opacity(0.48))
            }
            .font(.system(size: 8.5, weight: .semibold))
            .frame(height: 12)

            DailyUsageEnergyChart(
                points: model.dailyUsagePoints,
                average: model.dailyUsageAverage,
                selectedDate: model.selectedDailyReportDate
            )
            .frame(height: 58)

            HStack {
                Label(model.selectedDailyUsageComparisonText, systemImage: "waveform.path.ecg")
                Spacer()
                Text(text("数据仅保存在本机", "Local data only"))
            }
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.44))
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .overlay {
            if model.shouldCelebrateDailyReport {
                DailyReportCelebration()
                    .allowsHitTesting(false)
            }
        }
    }

    private func reportWeekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.usesEnglish
            ? Locale(identifier: "en_US")
            : Locale(identifier: "zh_CN")
        formatter.dateFormat = AppLanguage.current.usesEnglish ? "EE" : "E"
        return formatter.string(from: date)
    }

    private func reportDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: date)
    }

    private var expandedUsageColor: Color {
        switch model.remainingUsageLevel {
        case .low: .orange
        case .critical: .red
        default: .white.opacity(0.56)
        }
    }

    private func phaseText(_ phase: CodexActivity.Phase) -> String {
        if model.connectionState == .reconnecting { return text("正在重连", "Reconnecting") }
        return switch phase {
        case .running: text("运行中", "Running")
        case .review: text("分析中", "Analyzing")
        case .inputRequired: text("需要输入", "Input required")
        case .waiting: text("等待确认", "Waiting")
        case .completed: text("已完成", "Completed")
        case .failed: text("遇到问题", "Issue")
        case .idle: text("空闲", "Idle")
        }
    }

    private func taskUsageLine(_ task: CodexTaskItem) -> String {
        let effort = text("推理 \(effortText(task.effort))", "Reasoning \(effortText(task.effort))")
        guard let totalTokens = task.totalTokens else { return effort }
        return "\(effort) · \(compactTokenText(totalTokens)) Token"
    }

    private func compactTokenText(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        }
        if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }

    private func statusColor(_ task: CodexTaskItem) -> Color {
        if model.connectionState == .disconnected || model.connectionState == .reconnecting { return .red }
        if model.connectionState == .reconnected { return .cyan }
        if isTaskStale(task) { return .orange }
        return switch task.phase {
        case .inputRequired: .orange
        case .waiting: .orange
        case .failed: .red
        default: .green
        }
    }

    private func isTaskStale(_ task: CodexTaskItem) -> Bool {
        guard task.phase == .running || task.phase == .review else { return false }
        return model.clockTick.timeIntervalSince(task.lastActivityAt) >= 10 * 60
    }

    private func modelName(_ value: String) -> String {
        value
            .replacingOccurrences(of: "gpt-", with: "")
            .replacingOccurrences(of: "-sol", with: " Sol")
            .replacingOccurrences(of: "-terra", with: " Terra")
    }

    private func effortText(_ value: String) -> String {
        switch value.lowercased() {
        case "low": text("轻度", "Low")
        case "medium": text("中度", "Medium")
        case "high": text("高度", "High")
        case "xhigh": text("极高", "Extra high")
        default: value
        }
    }

    private func elapsedText(_ startedAt: Date?) -> String {
        guard let startedAt else { return "--:--" }
        let seconds = max(0, Int(model.clockTick.timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func persistentTaskStatus(_ task: CodexTaskItem) -> some View {
        HStack(spacing: 2) {
            Button {
                if model.activeTasks.count > 1 {
                    model.toggleTaskStatusPinned()
                } else {
                    model.openTask(task)
                }
            } label: {
                HStack(spacing: 9) {
                    Circle()
                        .fill(statusColor(task))
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title)
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(task.detail)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if model.activeTaskCount > 1 {
                        HStack(spacing: 3) {
                            Text("+\(model.activeTaskCount - 1)")
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7.5, weight: .black))
                        }
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(.white.opacity(0.1), in: Capsule())
                    }
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(modelName(task.model))
                        Text(taskUsageLine(task))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.leading, 13)
                .padding(.trailing, 4)
                .frame(maxWidth: .infinity, minHeight: 42)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.activeTaskCount > 1
                ? text("展开全部任务", "Show all tasks")
                : text("返回 Codex 对话", "Return to Codex conversation"))

            Button(action: model.toggleTaskDisplayCollapsed) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 8.5, weight: .black))
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .help(text("收起任务详情", "Collapse task details"))
        }
    }

    private func completedTaskStatus(message: String, task: CodexTaskItem) -> some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(message)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button(action: model.toggleCompletionStackCollapsed) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 8.5, weight: .black))
                    .foregroundStyle(.white.opacity(0.66))
                    .frame(width: 24, height: 24)
                    .background(.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .help(text("收起已完成任务", "Collapse completed tasks"))
            Button {
                withAnimation(.smooth(duration: 0.22)) {
                    model.acknowledgeCompletedTask(task)
                }
            } label: {
                CompletionCheckAnimation(
                    size: 28,
                    lineWidth: 2.2,
                    fill: Color(red: 0.72, green: 0.94, blue: 0.79),
                    stroke: Color(red: 0.12, green: 0.7, blue: 0.34),
                    check: Color(red: 0.1, green: 0.55, blue: 0.28)
                )
                .id(task.id)
            }
            .buttonStyle(.plain)
            .help(text("查看已完成任务", "View completed task"))
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, minHeight: 42)
    }

    private func compactCompletedTaskStatus(_ task: CodexTaskItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.down.right.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
            Text(task.title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.76))
                .lineLimit(1)
            Spacer(minLength: 4)
            if model.pendingCompletionCount > 1 {
                Text("+\(model.pendingCompletionCount - 1)")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
            }
            Button(action: model.toggleCompletionStackCollapsed) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 7.5, weight: .black))
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(width: 22, height: 22)
                    .background(.white.opacity(0.09), in: Circle())
            }
            .buttonStyle(.plain)
            .help(text("收起已完成任务", "Collapse completed tasks"))
            Button {
                withAnimation(.smooth(duration: 0.22)) {
                    model.acknowledgeCompletedTask(task)
                }
            } label: {
                CompletionCheckAnimation(
                    size: 24,
                    lineWidth: 2,
                    fill: Color(red: 0.72, green: 0.94, blue: 0.79),
                    stroke: Color(red: 0.12, green: 0.7, blue: 0.34),
                    check: Color(red: 0.1, green: 0.55, blue: 0.28)
                )
                .id(task.id)
            }
            .buttonStyle(.plain)
            .help(text("查看已完成任务", "View completed task"))
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, minHeight: 36)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)
        }
        .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
    }

    private func confirmationCard(_ task: CodexTaskItem) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(text("等待确认 · 返回对话后继续", "Waiting for confirmation · Return to continue"))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: model.toggleTaskDisplayCollapsed) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 8.5, weight: .black))
                    .foregroundStyle(.white.opacity(0.66))
                    .frame(width: 24, height: 30)
            }
            .buttonStyle(.plain)
            .help(text("收起任务详情", "Collapse task details"))

            Button { model.openTask(task) } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .help(text("返回对话", "Return to conversation"))

            Button { model.openTask(task) } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(red: 0.1, green: 0.55, blue: 0.28))
                    .frame(width: 30, height: 30)
                    .background(Color(red: 0.72, green: 0.94, blue: 0.79), in: Circle())
            }
            .buttonStyle(.plain)
            .help(text("前往确认", "Open confirmation"))
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, minHeight: 48)
    }

    private func inputRequiredCard(_ task: CodexTaskItem) -> some View {
        HStack(spacing: 2) {
            Button { model.openTask(task) } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(.orange)
                        .frame(width: 7, height: 7)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(task.detail.isEmpty
                             ? text("需要用户输入 · 点击返回对话", "Input required · Open conversation")
                             : task.detail)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    HStack(spacing: 5) {
                        Text(text("需输入", "Input"))
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(.orange.opacity(0.14), in: Capsule())
                }
                .padding(.leading, 13)
                .padding(.trailing, 4)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(text("返回对话填写内容", "Return to conversation and respond"))

            Button(action: model.toggleTaskDisplayCollapsed) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 8.5, weight: .black))
                    .foregroundStyle(.white.opacity(0.66))
                    .frame(width: 24, height: 30)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .help(text("收起任务详情", "Collapse task details"))
        }
    }

    private var settingsContent: some View {
        NotchSettingsContent(model: model)
            .padding(.horizontal, 13)
            .padding(.bottom, 12)
    }

    private var taskSearchContent: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.white.opacity(0.5))
                TextField(text("搜索任务或项目", "Search tasks or projects"), text: $model.taskSearchQuery)
                    .textFieldStyle(.plain)
                    .focused($taskSearchFocused)
                    .onSubmit {
                        if let task = model.taskSearchResults.first {
                            model.closeTaskSearch()
                            model.openTask(task)
                        }
                    }
                Button(action: model.closeTaskSearch) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.86))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(.white.opacity(0.07), in: Capsule())

            if model.taskSearchResults.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "text.magnifyingglass")
                    Text(text("没有找到本地任务", "No local tasks found"))
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.42))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.taskSearchResults) { task in
                            Button {
                                model.closeTaskSearch()
                                model.openTask(task)
                            } label: {
                                HStack(spacing: 9) {
                                    Circle()
                                        .fill(statusColor(task))
                                        .frame(width: 6, height: 6)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(task.title)
                                            .font(.system(size: 10.5, weight: .bold))
                                            .foregroundStyle(.white.opacity(0.9))
                                            .lineLimit(1)
                                        Text("\(task.project) · \(phaseText(task.phase))")
                                            .font(.system(size: 8.5, weight: .semibold))
                                            .foregroundStyle(.white.opacity(0.42))
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 8.5, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.35))
                                }
                                .padding(.horizontal, 8)
                                .frame(height: 37)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if task.id != model.taskSearchResults.last?.id {
                                Divider().overlay(.white.opacity(0.07))
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.bottom, 12)
    }

    private var expandedContent: some View {
        VStack(spacing: 8) {
            HStack {
                Text(model.latestDrop)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                Spacer()
                Button {
                    if model.pendingDropPrompt == nil {
                        model.collapse()
                    } else {
                        model.cancelPendingDrop()
                    }
                } label: {
                    Image(systemName: model.pendingDropPrompt == nil ? "chevron.up" : "xmark")
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.plain)
                .help(model.pendingDropPrompt == nil
                    ? text("收起", "Collapse")
                    : text("取消", "Cancel"))
            }

            if model.pendingDropPrompt != nil {
                HStack(spacing: 7) {
                    ForEach(model.pendingDropActions) { action in
                        Button {
                            model.startNewConversationFromDrop(action)
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: action.icon)
                                Text(action.title)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(.white, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.down.doc.fill")
                    Text(model.isDropTargeted
                        ? text("松开，交给 Codex", "Release to send to Codex")
                        : text("把文件、网址或文字拖到这里", "Drop a file, URL, or text here"))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.isDropTargeted ? .white : .white.opacity(0.55))
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 11)
    }
}

private struct LowUsageAnimatedText: View {
    let value: String
    let color: Color
    @State private var highlighted = false
    @State private var settled = false

    var body: some View {
        Text(value)
            .font(.system(size: 11, weight: .black, design: .rounded))
            .foregroundStyle(highlighted ? color : .white.opacity(0.92))
            .scaleEffect(highlighted && !settled ? 1.08 : (highlighted ? 1 : 0.96), anchor: .leading)
            .onAppear {
                withAnimation(.smooth(duration: 0.55)) {
                    highlighted = true
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(550))
                    withAnimation(.easeOut(duration: 0.24)) {
                        settled = true
                    }
                }
            }
    }
}

private struct DailyUsageHeatGrid: View {
    let points: [DailyUsagePoint]
    let selectedDate: Date
    let onSelect: (Date) -> Void

    private var maximum: Int {
        max(points.map(\.tokens).max() ?? 1, 1)
    }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7),
            spacing: 5
        ) {
            ForEach(points) { point in
                Button {
                    onSelect(point.day)
                } label: {
                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.09), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: max(0.04, CGFloat(point.tokens) / CGFloat(maximum)))
                            .stroke(
                                point.tokens > 0
                                    ? AnyShapeStyle(.linearGradient(
                                        colors: [.cyan, .blue, .purple],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ))
                                    : AnyShapeStyle(.white.opacity(0.05)),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                        Text(dayText(point.day))
                            .font(.system(size: 7.5, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(point.tokens > 0 ? 0.82 : 0.28))
                    }
                    .frame(width: 24, height: 24)
                    .overlay {
                        if Calendar.current.isDate(point.day, inSameDayAs: selectedDate) {
                            Circle().stroke(.white.opacity(0.82), lineWidth: 1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: date)
    }
}

private struct DailyReportCelebration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(0..<12, id: \.self) { index in
                    let angle = Double(index) / 12 * Double.pi * 2
                    let radius: CGFloat = expanded ? 72 + CGFloat(index % 3) * 10 : 8
                    Image(systemName: index.isMultiple(of: 3) ? "sparkle" : "circle.fill")
                        .font(.system(size: index.isMultiple(of: 3) ? 7 : 4, weight: .bold))
                        .foregroundStyle([Color.cyan, .purple, .pink, .orange][index % 4])
                        .position(x: proxy.size.width / 2, y: 42)
                        .offset(
                            x: cos(angle) * radius,
                            y: sin(angle) * radius * 0.45
                        )
                        .opacity(expanded ? 0 : 0.9)
                        .scaleEffect(expanded ? 0.4 : 1)
                }
            }
        }
        .onAppear {
            guard !reduceMotion else {
                expanded = true
                return
            }
            withAnimation(.easeOut(duration: 0.85)) {
                expanded = true
            }
        }
    }
}

private struct CompletionCheckAnimation: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let size: CGFloat
    let lineWidth: CGFloat
    let fill: Color
    let stroke: Color
    let check: Color
    @State private var ringProgress: CGFloat = 0
    @State private var checkVisible = false

    var body: some View {
        ZStack {
            Circle().fill(fill)
            Circle()
                .stroke(stroke.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: ringProgress)
                .stroke(
                    stroke,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.43, weight: .black))
                .foregroundStyle(check)
                .scaleEffect(checkVisible ? 1 : 0.35)
                .opacity(checkVisible ? 1 : 0)
        }
        .frame(width: size, height: size)
        .onAppear {
            if reduceMotion {
                ringProgress = 1
                checkVisible = true
                return
            }
            withAnimation(.easeInOut(duration: 0.34)) {
                ringProgress = 1
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(220))
                withAnimation(.spring(response: 0.28, dampingFraction: 0.62)) {
                    checkVisible = true
                }
            }
        }
    }
}

private struct DailyUsageEnergyChart: View {
    let points: [DailyUsagePoint]
    let average: Int
    let selectedDate: Date

    var body: some View {
        GeometryReader { proxy in
            let chartHeight = max(1, proxy.size.height - 20)
            let maximum = max(points.map(\.tokens).max() ?? 1, average, 1)
            let positions = points.enumerated().map { index, point in
                CGPoint(
                    x: points.count > 1
                        ? CGFloat(index) / CGFloat(points.count - 1) * proxy.size.width
                        : proxy.size.width,
                    y: chartHeight - CGFloat(point.tokens) / CGFloat(maximum) * (chartHeight - 12) + 6
                )
            }

            Canvas { context, size in
                guard let first = positions.first, let last = positions.last else { return }
                if average > 0 {
                    let y = chartHeight - CGFloat(average) / CGFloat(maximum) * (chartHeight - 12) + 6
                    var baseline = Path()
                    baseline.move(to: CGPoint(x: 0, y: y))
                    baseline.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(
                        baseline,
                        with: .color(.white.opacity(0.16)),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 4])
                    )
                }

                var area = Path()
                area.move(to: CGPoint(x: first.x, y: chartHeight))
                positions.forEach { area.addLine(to: $0) }
                area.addLine(to: CGPoint(x: last.x, y: chartHeight))
                area.closeSubpath()
                context.fill(
                    area,
                    with: .linearGradient(
                        Gradient(colors: [.cyan.opacity(0.34), .purple.opacity(0.08), .clear]),
                        startPoint: CGPoint(x: size.width, y: 0),
                        endPoint: CGPoint(x: 0, y: chartHeight)
                    )
                )

                var line = Path()
                line.move(to: first)
                positions.dropFirst().forEach { line.addLine(to: $0) }
                context.drawLayer { glow in
                    glow.addFilter(.blur(radius: 7))
                    glow.stroke(line, with: .color(.cyan.opacity(0.48)), lineWidth: 6)
                }
                context.stroke(
                    line,
                    with: .linearGradient(
                        Gradient(colors: [.pink, .purple, .blue, .cyan]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: 0)
                    ),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                )
                for (index, position) in positions.enumerated() where points[index].tokens > 0 {
                    let selected = Calendar.current.isDate(points[index].day, inSameDayAs: selectedDate)
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: position.x - (selected ? 4 : 2.5),
                            y: position.y - (selected ? 4 : 2.5),
                            width: selected ? 8 : 5,
                            height: selected ? 8 : 5
                        )),
                        with: .color(selected ? .cyan : .white.opacity(0.7))
                    )
                }
            }
            .overlay(alignment: .bottom) {
                HStack {
                    ForEach(points) { point in
                        Text(shortWeekday(point.day))
                            .frame(maxWidth: .infinity)
                    }
                }
                .font(.system(size: 7.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.34))
            }
        }
    }

    private func shortWeekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.usesEnglish
            ? Locale(identifier: "en_US")
            : Locale(identifier: "zh_CN")
        formatter.dateFormat = AppLanguage.current.usesEnglish ? "EEE" : "E"
        return formatter.string(from: date)
    }
}

private struct NotchSettingsContent: View {
    private enum Section: CaseIterable {
        case general
        case features
        case about
    }

    @ObservedObject var model: NotchModel
    @AppStorage("coexistenceMode") private var coexistenceMode = CoexistenceMode.automatic.rawValue
    @AppStorage("screenNumber") private var screenNumber = -1
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue
    @AppStorage("dailyReportEnabled") private var dailyReportEnabled = true
    @AppStorage("dailyReportHour") private var dailyReportHour = 18
    @AppStorage("dailyReportMinute") private var dailyReportMinute = 30
    @State private var selectedSection: Section = .general

    private func text(_ chinese: String, _ english: String) -> String {
        (AppLanguage(rawValue: appLanguage) ?? .system).usesEnglish ? english : chinese
    }

    var body: some View {
        VStack(spacing: 8) {
            sectionPicker

            Group {
                switch selectedSection {
                case .general:
                    generalSettings
                case .features:
                    featureSettings
                case .about:
                    aboutSettings
                }
            }
            .transition(.opacity)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(.white.opacity(0.82))
        .animation(.easeOut(duration: 0.14), value: selectedSection)
        .onChange(of: coexistenceMode) { _, _ in notifyChange() }
        .onChange(of: screenNumber) { _, _ in notifyChange() }
        .onChange(of: appLanguage) { _, _ in notifyChange() }
        .onChange(of: dailyReportEnabled) { _, _ in notifyChange() }
        .onChange(of: dailyReportHour) { _, _ in notifyChange() }
        .onChange(of: dailyReportMinute) { _, _ in notifyChange() }
    }

    private var sectionPicker: some View {
        HStack(spacing: 4) {
            sectionButton(.general, title: text("通用", "General"), icon: "slider.horizontal.3")
            sectionButton(.features, title: text("功能", "Features"), icon: "sparkles")
            sectionButton(.about, title: text("关于", "About"), icon: "info.circle")
        }
        .padding(3)
        .background(.white.opacity(0.06), in: Capsule())
    }

    private func sectionButton(_ section: Section, title: String, icon: String) -> some View {
        Button {
            selectedSection = section
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                Text(title)
                    .font(.system(size: 9.5, weight: .bold))
            }
            .foregroundStyle(selectedSection == section ? .black : .white.opacity(0.58))
            .frame(maxWidth: .infinity, minHeight: 25)
            .background(selectedSection == section ? .white : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var generalSettings: some View {
        VStack(spacing: 8) {
            settingRow(
                icon: "rectangle.2.swap",
                title: text("共存", "Coexistence"),
                detail: text("识别 BoringNotch 与 NotchNook", "Detect BoringNotch and NotchNook"),
                value: coexistenceMode == CoexistenceMode.alwaysShow.rawValue
                    ? text("始终显示", "Always show")
                    : text("检测后询问", "Ask when detected")
            ) {
                coexistenceMode = coexistenceMode == CoexistenceMode.automatic.rawValue
                    ? CoexistenceMode.alwaysShow.rawValue : CoexistenceMode.automatic.rawValue
            }

            settingRow(
                icon: "display",
                title: text("屏幕", "Display"),
                detail: text("无刘海屏幕使用薄顶部胶囊", "Slim capsule without a notch"),
                value: selectedScreenName
            ) {
                cycleScreen()
            }

            settingRow(
                icon: "globe",
                title: text("语言", "Language"),
                detail: text("默认跟随 macOS 系统语言", "Follow macOS by default"),
                value: selectedLanguage.displayName
            ) {
                cycleLanguage()
            }
        }
    }

    private var featureSettings: some View {
        VStack(spacing: 8) {
            dailyReportSettingRow

            settingRow(
                icon: model.availableUpdate != nil
                    ? "arrow.down.circle.fill"
                    : (model.hasCheckedForUpdate ? "checkmark.circle" : "arrow.clockwise.circle"),
                title: text("软件更新", "Software Update"),
                detail: model.availableUpdate == nil
                    ? text("每天自动检查一次", "Checked automatically once a day")
                    : text("点击下载官方 DMG", "Download the official DMG"),
                value: model.updateStatusText
            ) {
                model.performUpdateAction()
            }
        }
    }

    private var aboutSettings: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                externalLinkButton(
                    icon: "globe",
                    title: text("官方网站", "Website"),
                    url: "https://codexnotch.pages.dev/"
                )
                externalLinkButton(
                    icon: "chevron.left.forwardslash.chevron.right",
                    title: "GitHub",
                    url: "https://github.com/VibeDough/CodexNotch"
                )
            }

            HStack(spacing: 9) {
                Image(systemName: "person.crop.circle")
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Henry恒宇").fontWeight(.bold)
                    Text("@VibeDough")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                Text("CodexNotch \(model.appVersion)")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))
            }
            .frame(minHeight: 30)
        }
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: .notchPreferencesChanged, object: nil)
    }

    private var selectedScreenName: String {
        guard screenNumber >= 0 else {
            return NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
                ? text("内建刘海屏", "Built-in notch display")
                : text("当前主屏", "Current main display")
        }
        return NSScreen.screens.first { screenNumberValue($0) == screenNumber }?.localizedName
            ?? text("当前主屏", "Current main display")
    }

    private var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguage) ?? .system
    }

    private func cycleLanguage() {
        let languages = AppLanguage.allCases
        let index = languages.firstIndex(of: selectedLanguage) ?? 0
        appLanguage = languages[(index + 1) % languages.count].rawValue
    }

    private func cycleScreen() {
        let values = [-1] + NSScreen.screens.compactMap(screenNumberValue)
        let index = values.firstIndex(of: screenNumber) ?? 0
        screenNumber = values[(index + 1) % values.count]
    }

    private func screenNumberValue(_ screen: NSScreen) -> Int? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue
    }

    private var dailyReportSettingRow: some View {
        HStack(spacing: 9) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(text("日报提醒", "Daily report")).fontWeight(.bold)
                Text(text("任务空闲后提醒 8 秒", "8-second reminder when idle"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 5)
            Menu {
                ForEach(reportTimeOptions, id: \.self) { total in
                    let hour = total / 60
                    let minute = total % 60
                    let label = String(format: "%02d:%02d", hour, minute)
                    Button {
                        dailyReportHour = hour
                        dailyReportMinute = minute
                    } label: {
                        if hour == dailyReportHour, minute == dailyReportMinute {
                            Label(label, systemImage: "checkmark")
                        } else {
                            Text(label)
                        }
                    }
                }
            } label: {
                Text(reportTimeLabel)
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(dailyReportEnabled ? 0.86 : 0.38))
                    .padding(.horizontal, 8)
                    .frame(height: 25)
                    .background(.white.opacity(0.09), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .disabled(!dailyReportEnabled)

            Button {
                dailyReportEnabled.toggle()
            } label: {
                Image(systemName: dailyReportEnabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(dailyReportEnabled ? .green : .white.opacity(0.38))
                    .frame(width: 24, height: 25)
            }
            .buttonStyle(.plain)
            .help(dailyReportEnabled
                ? text("关闭自动提醒", "Disable reminder")
                : text("开启自动提醒", "Enable reminder"))
        }
    }

    private var reportTimeLabel: String {
        String(format: "%02d:%02d", dailyReportHour, dailyReportMinute)
    }

    private var reportTimeOptions: [Int] {
        Array(stride(from: 15 * 60, through: 21 * 60, by: 30))
    }

    private func externalLinkButton(icon: String, title: String, url: String) -> some View {
        Button {
            guard let destination = URL(string: url) else { return }
            NSWorkspace.shared.open(destination)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(size: 9.5, weight: .bold))
                Spacer(minLength: 2)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.42))
            }
            .foregroundStyle(.white.opacity(0.82))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(.white.opacity(0.08), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private func settingRow(
        icon: String,
        title: String,
        detail: String,
        value: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.bold)
                Text(detail)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 5)
            Button(action: action) {
                HStack(spacing: 4) {
                    Text(value).lineLimit(1)
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .padding(.horizontal, 8)
                .frame(height: 25)
                .background(.white.opacity(0.09), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct EdgeGlowBorder: View {
    let compact: Bool
    let expanded: Bool
    let animated: Bool
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !animated)) { timeline in
            Canvas { context, size in
                let angle = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 2.8) / 2.8 * 360
                let bounds = CGRect(origin: .zero, size: size)
                let rect = compact ? bounds.insetBy(dx: 1.4, dy: 1.4) : bounds
                let path = compact
                    ? Capsule().path(in: rect)
                    : IslandEdgeShape(shoulder: 0, bottomRadius: expanded ? 18 : 12).path(in: rect)
                if animated {
                    context.stroke(path, with: .color(.white.opacity(0.07)), lineWidth: 1)
                }
                let gradient = Gradient(stops: animated
                    ? [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.52),
                        .init(color: .purple.opacity(0.18), location: 0.61),
                        .init(color: .purple, location: 0.69),
                        .init(color: .blue, location: 0.76),
                        .init(color: .cyan, location: 0.82),
                        .init(color: .white.opacity(0.95), location: 0.85),
                        .init(color: .cyan, location: 0.88),
                        .init(color: .blue.opacity(0.42), location: 0.94),
                        .init(color: .clear, location: 1)
                    ]
                    : [
                        .init(color: color, location: 0),
                        .init(color: color, location: 1)
                    ])
                context.stroke(
                    path,
                    with: .conicGradient(
                        gradient,
                        center: CGPoint(x: size.width / 2, y: size.height / 2),
                        angle: .degrees(angle)
                    ),
                    style: StrokeStyle(lineWidth: 2.7, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .allowsHitTesting(false)
    }
}

private struct IslandEdgeShape: Shape {
    let shoulder: CGFloat
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let edgeInset: CGFloat = 1.4
        let s = min(shoulder, rect.width / 5) + edgeInset
        let rightX = rect.maxX - s
        let bottomY = rect.maxY - edgeInset
        let r = min(
            max(0, bottomRadius - edgeInset),
            (bottomY - rect.minY) / 2
        )
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + s, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + s, y: bottomY - r))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + s + r, y: bottomY),
            control: CGPoint(x: rect.minX + s, y: bottomY)
        )
        path.addLine(to: CGPoint(x: rightX - r, y: bottomY))
        path.addQuadCurve(
            to: CGPoint(x: rightX, y: bottomY - r),
            control: CGPoint(x: rightX, y: bottomY)
        )
        path.addLine(to: CGPoint(x: rightX, y: rect.minY))
        return path
    }
}
