import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NotchView: View {
    @ObservedObject var model: NotchModel

    private var showsTaskDetails: Bool {
        model.isTaskStatusPinned && model.activeTasks.count > 1
    }

    private var showsUsageDetails: Bool {
        model.isHovered && model.activeTasks.isEmpty
    }

    private var showsDetails: Bool {
        showsTaskDetails || showsUsageDetails || model.isShowingSettings
    }

    var body: some View {
        VStack(spacing: 0) {
            collapsedBar

            if model.isExpanded {
                EmptyView()
            } else if model.isShowingSettings {
                settingsContent
            } else if let task = model.waitingTask {
                confirmationCard(task)
            } else if showsTaskDetails {
                taskDetails
            } else if let task = model.primaryTask {
                VStack(spacing: 0) {
                    persistentTaskStatus(task)
                    if let completedTask = model.completedTask,
                       model.visibleCompletionMessage != nil {
                        compactCompletedTaskStatus(completedTask)
                    }
                }
            } else if let message = model.visibleCompletionMessage,
                      let task = model.completedTask {
                completedTaskStatus(message: message, task: task)
            } else if model.activeTasks.isEmpty,
                      model.visibleCompletionMessage == nil,
                      !model.isExpanded {
                tokenDetails
                    .opacity(showsUsageDetails ? 1 : 0)
                    .transition(.opacity)
            } else if let message = model.visibleCompletionMessage {
                completionBubble(message)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.62, anchor: .top).combined(with: .opacity),
                        removal: .scale(scale: 0.88, anchor: .top).combined(with: .opacity)
                    ))
            }

            if model.isExpanded {
                expandedContent
                    .background(.black)
                    .clipShape(.rect(bottomLeadingRadius: 18, bottomTrailingRadius: 18))
                    .transition(.scale(scale: 0.92, anchor: .top).combined(with: .opacity))
            }
        }
        .frame(width: visualSize.width, height: visualSize.height, alignment: .top)
        .ignoresSafeArea(.all)
        .background {
            if model.usesCompactBar && !showsDetails && !model.isExpanded {
                Capsule().fill(.black)
            } else {
                IslandShape(
                    shoulder: 0,
                    bottomRadius: showsDetails || model.primaryTask != nil || model.visibleCompletionMessage != nil
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
        .animation(.spring(response: 0.34, dampingFraction: 0.72), value: model.completionMessage)
        .animation(.smooth(duration: 0.22), value: model.presentationMode)
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
                        Image(systemName: "link.slash")
                        Text("断开")
                    } else if model.connectionState == .reconnected {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("已重连")
                    } else if model.isHovered {
                        Text(model.activeTasks.isEmpty ? "用量" : "任务")
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
            .help("打开 Codex")
            .scaleEffect(x: usesSmallIdleLayout ? 0.84 : 1, y: 1, anchor: .leading)

            Spacer(minLength: 92)

            ZStack {
                Group {
                    if model.activeTasks.count > 1 {
                        Button { model.toggleTaskStatusPinned() } label: { taskStatus }
                            .buttonStyle(.plain)
                            .help(model.isTaskStatusPinned ? "取消常驻任务" : "常驻显示任务")
                    } else {
                        taskStatus
                    }
                }
                .opacity(model.isHovered ? 0 : 1)

                if model.isHovered {
                    HStack(spacing: 8) {
                        Button(action: model.toggleSettings) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(model.isShowingSettings ? .black : .white)
                                .frame(width: 28, height: 28)
                                .background(model.isShowingSettings ? .white : .white.opacity(0.1), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("设置")

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
                        .help("退出")
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
        .onTapGesture {
            if model.activeTasks.count > 1 {
                model.toggleTaskStatusPinned()
            } else if let task = model.primaryTask {
                model.openTask(task)
            } else {
                model.toggleExpanded()
            }
        }
        .overlay {
            IslandShape(shoulder: 5, bottomRadius: 12)
                .stroke(model.isDropTargeted ? Color.white.opacity(0.75) : .clear, lineWidth: 1)
        }
        .contextMenu {
            Button("退出") { NSApplication.shared.terminate(nil) }
        }
    }

    private var collapsedBarHeight: CGFloat {
        let isIdle = model.activeTasks.isEmpty
            && model.visibleCompletionMessage == nil
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

    private var usesSmallIdleLayout: Bool {
        !model.usesCompactBar
            && model.activeTasks.isEmpty
            && model.visibleCompletionMessage == nil
            && model.waitingTask == nil
            && !model.isHovered
            && !model.isExpanded
            && !model.isShowingSettings
    }

    @ViewBuilder
    private var edgeStatusGlow: some View {
        if model.connectionState == .disconnected {
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
        .accessibilityLabel("正在执行 \(model.activeTaskCount) 个任务")
    }

    private var currentStatusText: String {
        guard model.activeTaskCount > 0 else { return "空闲" }
        return switch currentActivePhase {
        case .waiting: "等待"
        case .failed: "异常"
        case .review: "分析"
        default: "运行"
        }
    }

    private var currentStatusColor: Color {
        if model.connectionState == .disconnected { return .red }
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
                            Text("\(phaseText(task.phase)) · \(elapsedText(task.startedAt))")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                        }

                        Spacer(minLength: 8)

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(modelName(task.model))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.78))
                            Text("推理 \(effortText(task.effort))")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .frame(height: 40)
                }
                .buttonStyle(.plain)
                .help("返回 Codex 对话")

                if task.id != model.activeTasks.last?.id {
                    Divider().overlay(.white.opacity(0.08))
                }
            }

            if model.activeTasks.count > 1 {
                Button { model.toggleTaskStatusPinned() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 8.5, weight: .black))
                        Text("收起任务")
                            .font(.system(size: 9.5, weight: .bold))
                    }
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("收起任务列表")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var usageDetails: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("剩余额度")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(model.remainingUsageText)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                Spacer()
                Text(model.planText)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }

            GeometryReader { proxy in
                Capsule().fill(.white.opacity(0.1))
                Capsule()
                    .fill(model.usageProgress < 0.2 ? .orange : .white)
                    .frame(width: proxy.size.width * model.usageProgress)
            }
            .frame(height: 4)

            HStack {
                Label("重置 \(model.resetCountdownText)", systemImage: "clock")
                Spacer()
                Text("版本 \(model.codexVersion)")
            }
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.58))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var tokenDetails: some View {
        VStack(spacing: 9) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("今日消耗")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                    Text(model.todayTokenText)
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                }
                Spacer()
                Text(model.planText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }

            HStack {
                Label(model.remainingUsageStatusText, systemImage: "gauge.with.dots.needle.50percent")
                    .foregroundStyle(expandedUsageColor)
                Spacer()
                Text("版本 \(model.codexVersion)")
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
        return switch phase {
        case .running: "运行中"
        case .review: "分析中"
        case .waiting: "等待确认"
        case .completed: "已完成"
        case .failed: "遇到问题"
        case .idle: "空闲"
        }
    }

    private func statusColor(_ phase: CodexActivity.Phase) -> Color {
        if model.connectionState == .disconnected { return .red }
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
        case "low": "轻度"
        case "medium": "中度"
        case "high": "高度"
        case "xhigh": "极高"
        default: value
        }
    }

    private func elapsedText(_ startedAt: Date?) -> String {
        guard let startedAt else { return "--:--" }
        let seconds = max(0, Int(model.clockTick.timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func completionBubble(_ message: String) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 8)
            Text(message)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            ZStack {
                Circle()
                    .fill(.white.opacity(0.13))
                    .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 1))
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.white)
            }
            .frame(width: 20, height: 20)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, minHeight: 40)
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
                    Text("\(phaseText(task.phase)) · \(elapsedText(task.startedAt))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
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
                    Text("推理 \(effortText(task.effort))")
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
        .help(model.activeTaskCount > 1 ? "展开全部任务" : "返回 Codex 对话")
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
            Button { model.acknowledgeCompletedTask(task) } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Color(red: 0.1, green: 0.55, blue: 0.28))
                    .frame(width: 28, height: 28)
                    .background(Color(red: 0.72, green: 0.94, blue: 0.79), in: Circle())
            }
            .buttonStyle(.plain)
            .help("查看已完成任务")
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
            Button { model.acknowledgeCompletedTask(task) } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Color(red: 0.1, green: 0.55, blue: 0.28))
                    .frame(width: 24, height: 24)
                    .background(Color(red: 0.72, green: 0.94, blue: 0.79), in: Circle())
            }
            .buttonStyle(.plain)
            .help("查看已完成任务")
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, minHeight: 36)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func confirmationCard(_ task: CodexTaskItem) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("等待确认 · 返回对话后继续")
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
            .help("返回对话")

            Button { model.openTask(task) } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color(red: 0.1, green: 0.55, blue: 0.28))
                    .frame(width: 30, height: 30)
                    .background(Color(red: 0.72, green: 0.94, blue: 0.79), in: Circle())
            }
            .buttonStyle(.plain)
            .help("前往确认")
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
                .help(model.pendingDropPrompt == nil ? "收起" : "取消")
            }

            if model.pendingDropPrompt != nil {
                Button(action: model.startNewConversationFromDrop) {
                    VStack(spacing: 2) {
                        HStack(spacing: 7) {
                            Image(systemName: "plus.message.fill")
                            Text("在 Codex 新建对话")
                        }
                        Text("拖入其他内容可替换")
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
                    Text(model.isDropTargeted ? "松开，交给 Codex" : "把文件、网址或文字拖到这里")
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

    var body: some View {
        VStack(spacing: 8) {
            settingRow(
                icon: "rectangle.2.swap",
                title: "共存",
                detail: "检测到其他刘海应用时自动避让",
                value: coexistenceMode == CoexistenceMode.alwaysShow.rawValue ? "始终显示" : "自动避让"
            ) {
                coexistenceMode = coexistenceMode == CoexistenceMode.automatic.rawValue
                    ? CoexistenceMode.alwaysShow.rawValue : CoexistenceMode.automatic.rawValue
            }

            settingRow(
                icon: "display",
                title: "屏幕",
                detail: "无刘海屏幕使用薄顶部胶囊",
                value: selectedScreenName
            ) {
                cycleScreen()
            }
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(.white.opacity(0.82))
        .onChange(of: coexistenceMode) { _, _ in notifyChange() }
        .onChange(of: screenNumber) { _, _ in notifyChange() }
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: .notchPreferencesChanged, object: nil)
    }

    private var selectedScreenName: String {
        guard screenNumber >= 0 else { return "当前主屏" }
        return NSScreen.screens.first { screenNumberValue($0) == screenNumber }?.localizedName ?? "当前主屏"
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
        GeometryReader { _ in
            TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !animated)) { timeline in
                let angle = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 2.8) / 2.8 * 360
                glowShape(angle: angle)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func glowShape(angle: Double) -> some View {
        let style = AngularGradient(
            colors: animated
                ? [.cyan, .blue, .purple, .pink, .orange, .green, .cyan]
                : [color, color],
            center: .center,
            angle: .degrees(angle)
        )
        if compact {
            Capsule()
                .stroke(style, lineWidth: 2.7)
                .shadow(color: color.opacity(0.65), radius: 2.8)
                .padding(1.4)
        } else {
            ZStack {
                IslandEdgeShape(shoulder: 0, bottomRadius: expanded ? 18 : 12)
                    .stroke(
                        style,
                        style: StrokeStyle(lineWidth: 2.7, lineCap: .round, lineJoin: .round)
                    )
                    .mask { EdgeBodyMask(tipHeight: 8).fill(.white) }

                EdgeTaperTips(tipHeight: 8, baseWidth: 2.7)
                    .fill(style)
            }
            .shadow(color: color.opacity(0.65), radius: 2.8)
        }
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

private struct EdgeBodyMask: Shape {
    let tipHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(
            x: rect.minX,
            y: min(tipHeight, rect.height),
            width: rect.width,
            height: max(0, rect.height - tipHeight)
        ))
    }
}

private struct EdgeTaperTips: Shape {
    let tipHeight: CGFloat
    let baseWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let height = min(tipHeight, rect.height)
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + height))
        path.addLine(to: CGPoint(x: rect.minX + baseWidth, y: rect.minY + height))
        path.closeSubpath()

        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - baseWidth, y: rect.minY + height))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + height))
        path.closeSubpath()
        return path
    }
}
