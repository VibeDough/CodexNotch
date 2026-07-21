import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NotchView: View {
    @ObservedObject var model: NotchModel
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue

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
    }

    var body: some View {
        VStack(spacing: 0) {
            collapsedBar

            if let task = model.waitingTask {
                confirmationCard(task)
            } else if model.isExpanded {
                EmptyView()
            } else if model.isShowingSettings {
                settingsContent
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
                        || (model.visibleCompletionMessage != nil && !model.isCompletionStackCollapsed)
                        || model.waitingTask != nil || model.isExpanded ? 18 : 12
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
        .onChange(of: appLanguage) { _, _ in model.refreshLanguage() }
        .onChange(of: model.isDropTargeted) { _, targeted in
            model.setDropTargeted(targeted)
        }
        .onDrop(of: [UTType.fileURL, UTType.url, UTType.utf8PlainText], isTargeted: $model.isDropTargeted) {
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

            Spacer(minLength: 92)

            ZStack {
                Group {
                    if model.hasCollapsedCompletion {
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
                .opacity(model.isHovered && !model.hasCollapsedCompletion ? 0 : 1)

                if model.isHovered && !model.hasCollapsedCompletion {
                    HStack(spacing: 8) {
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
                    .frame(width: 64, height: 28)
                    .transition(.scale(scale: 0.86, anchor: .trailing).combined(with: .opacity))
                }
            }
            .frame(width: 68, height: 28)
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
            EdgeGlowBorder(compact: model.usesCompactBar, expanded: showsDetails || model.primaryTask != nil, animated: false, color: .red)
        } else if model.activeTaskCount > 0 || model.connectionState == .reconnected {
            EdgeGlowBorder(compact: model.usesCompactBar, expanded: showsDetails || model.primaryTask != nil, animated: true, color: .cyan)
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
        }
        .frame(width: 68, height: 28, alignment: .trailing)
        .accessibilityLabel(text("正在执行 \(model.activeTaskCount) 个任务", "\(model.activeTaskCount) active tasks"))
    }

    private var completionCountBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .black))
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
        return switch currentActivePhase {
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
        return switch currentActivePhase {
        case .waiting: .orange
        case .failed: .red
        default: .green
        }
    }

    private var currentActivePhase: CodexActivity.Phase? {
        let priority: [CodexActivity.Phase] = [.waiting, .failed, .review, .running]
        return priority.first { phase in model.activeTasks.contains { $0.phase == phase } }
    }

    private var taskDetails: some View {
        VStack(spacing: 0) {
            ForEach(model.activeTasks) { task in
                Button { model.openTask(task) } label: {
                    HStack(spacing: 9) {
                        Circle()
                            .fill(statusColor(task.phase))
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
                }
                Spacer(minLength: 10)
                Button(action: model.openCodex) {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: 34)
                .allowsHitTesting(showsUsageDetails)
                .accessibilityLabel(text("打开 Codex", "Open Codex"))
                .help(text("打开 Codex", "Open Codex"))
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

    private func statusColor(_ phase: CodexActivity.Phase) -> Color {
        if model.connectionState == .disconnected || model.connectionState == .reconnecting { return .red }
        if model.connectionState == .reconnected { return .cyan }
        return switch phase {
        case .waiting: .orange
        case .failed: .red
        default: .green
        }
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
        Button {
            if model.activeTasks.count > 1 {
                model.toggleTaskStatusPinned()
            } else {
                model.openTask(task)
            }
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(statusColor(task.phase))
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
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity, minHeight: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.activeTaskCount > 1
            ? text("展开全部任务", "Show all tasks")
            : text("返回 Codex 对话", "Return to Codex conversation"))
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
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(red: 0.1, green: 0.55, blue: 0.28))
                    .frame(width: 28, height: 28)
                    .background(Color(red: 0.72, green: 0.94, blue: 0.79), in: Circle())
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
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Color(red: 0.1, green: 0.55, blue: 0.28))
                    .frame(width: 24, height: 24)
                    .background(Color(red: 0.72, green: 0.94, blue: 0.79), in: Circle())
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

    private var settingsContent: some View {
        NotchSettingsContent()
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
                Button(action: model.startNewConversationFromDrop) {
                    VStack(spacing: 2) {
                        HStack(spacing: 7) {
                            Image(systemName: "plus.message.fill")
                            Text(text("在 Codex 新建对话", "New conversation in Codex"))
                        }
                        Text(text("拖入其他内容可替换", "Drop something else to replace it"))
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.black.opacity(0.48))
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
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

private struct NotchSettingsContent: View {
    @AppStorage("coexistenceMode") private var coexistenceMode = CoexistenceMode.automatic.rawValue
    @AppStorage("screenNumber") private var screenNumber = -1
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue

    private func text(_ chinese: String, _ english: String) -> String {
        (AppLanguage(rawValue: appLanguage) ?? .system).usesEnglish ? english : chinese
    }

    var body: some View {
        VStack(spacing: 8) {
            settingRow(
                icon: "rectangle.2.swap",
                title: text("共存", "Coexistence"),
                detail: text("检测到其他刘海应用时自动避让", "Avoid other notch apps"),
                value: coexistenceMode == CoexistenceMode.alwaysShow.rawValue
                    ? text("始终显示", "Always show")
                    : text("自动避让", "Automatic")
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
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(.white.opacity(0.82))
        .onChange(of: coexistenceMode) { _, _ in notifyChange() }
        .onChange(of: screenNumber) { _, _ in notifyChange() }
        .onChange(of: appLanguage) { _, _ in notifyChange() }
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
