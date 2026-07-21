import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private struct KnownNotchApp {
        let name: String
        let bundleIdentifier: String
    }

    private static let knownNotchApps = [
        KnownNotchApp(name: "BoringNotch", bundleIdentifier: "theboringteam.boringnotch"),
        KnownNotchApp(name: "NotchNook", bundleIdentifier: "lo.cafe.NotchNook")
    ]

    private var panel: NotchPanel?
    private var hostingView: NSHostingView<NotchView>?
    private var environmentTimer: Timer?
    private var hoverTimer: Timer?
    private var pendingResizeTask: Task<Void, Never>?
    private var conflictDecisions: [String: Bool] = [:]
    private var isPresentingConflictPrompt = false
    private let model = NotchModel()
    private let preferences = AppPreferences()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installPanel()

        NotificationCenter.default.addObserver(
            forName: .notchSizeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.resizeForCurrentState()
                self?.refreshPresentation(reposition: false)
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPresentation(reposition: true) }
        }

        NotificationCenter.default.addObserver(
            forName: .notchPreferencesChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPresentation(reposition: true) }
        }

        environmentTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPresentation(reposition: false) }
        }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPointerHover() }
        }
        refreshPresentation(reposition: true)
        resizeForCurrentState()
    }

    private func installPanel() {
        let root = NotchView(model: model)
        let hostingView = NSHostingView(rootView: root)
        let initialSize = panelSize(expanded: false)
        hostingView.frame = NSRect(origin: .zero, size: initialSize)
        hostingView.autoresizingMask = [.width, .height]

        let panel = NotchPanel(
            contentRect: hostingView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.contentView?.autoresizingMask = [.width, .height]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.onEscape = { [weak self] in
            guard let self else { return }
            if self.model.pendingDropPrompt != nil {
                self.model.cancelPendingDrop()
            } else {
                self.model.collapse()
            }
        }
        self.hostingView = hostingView
        self.panel = panel
    }

    private func refreshPresentation(reposition: Bool) {
        guard let panel, let screen = preferences.targetScreen() else { return }
        model.setCompactBar(screen.safeAreaInsets.top <= 0)
        let conflicts = Self.knownNotchApps.filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleIdentifier).isEmpty
        }
        let activeBundleIdentifiers = Set(conflicts.map(\.bundleIdentifier))
        conflictDecisions = conflictDecisions.filter { activeBundleIdentifiers.contains($0.key) }
        let fullscreen = hasFullscreenWindow(on: screen)
        let hasImportantStatus = model.activeTaskCount > 0 || model.visibleCompletionMessage != nil
        let hiddenByConflict = preferences.coexistenceMode == .menuBarOnly
            || (preferences.coexistenceMode == .automatic
                && conflicts.contains { conflictDecisions[$0.bundleIdentifier] == true })
        let hiddenByFullscreen = fullscreen && !hasImportantStatus

        if hiddenByConflict || hiddenByFullscreen {
            panel.orderOut(nil)
        } else {
            if reposition || !panel.isVisible {
                position(panel, on: screen)
            }
            panel.orderFrontRegardless()
        }

        if preferences.coexistenceMode == .automatic,
           !isPresentingConflictPrompt,
           let conflict = conflicts.first(where: { conflictDecisions[$0.bundleIdentifier] == nil }) {
            presentConflictPrompt(for: conflict)
        }
    }

    private func presentConflictPrompt(for app: KnownNotchApp) {
        isPresentingConflictPrompt = true
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = AppLanguage.text(
            "检测到 \(app.name) 正在使用刘海区域",
            "\(app.name) is using the notch area"
        )
        alert.informativeText = AppLanguage.text(
            "是否暂时隐藏 CodexNotch？不会关闭或修改 \(app.name)。",
            "Temporarily hide CodexNotch? \(app.name) will not be closed or changed."
        )
        alert.addButton(withTitle: AppLanguage.text("暂时隐藏", "Hide CodexNotch"))
        alert.addButton(withTitle: AppLanguage.text("继续同时显示", "Keep Both Visible"))
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        conflictDecisions[app.bundleIdentifier] = response == .alertFirstButtonReturn
        isPresentingConflictPrompt = false
        refreshPresentation(reposition: false)
    }

    private func refreshPointerHover() {
        guard let panel, panel.isVisible else {
            model.setHovered(false)
            return
        }
        let visibleSize = notchSize(expanded: model.isExpanded)
        let visibleFrame = NSRect(
            x: panel.frame.midX - visibleSize.width / 2,
            y: panel.frame.maxY - visibleSize.height,
            width: visibleSize.width,
            height: visibleSize.height
        )
        let hitArea = visibleFrame.insetBy(dx: -10, dy: -8)
        model.setHovered(hitArea.contains(NSEvent.mouseLocation))
    }

    private func hasFullscreenWindow(on screen: NSScreen) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return windows.contains { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != getpid(),
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"],
                  let x = bounds["X"], let y = bounds["Y"] else { return false }
            let frame = screen.frame
            return abs(width - frame.width) < 3
                && abs(height - frame.height) < 3
                && abs(x - frame.minX) < 3
                && abs(y - (NSScreen.screens.map(\.frame.maxY).max() ?? frame.maxY) + frame.maxY) < 3
        }
    }

    private func position(_ panel: NSPanel, on screen: NSScreen) {
        let size = panelSize(expanded: model.isExpanded, on: screen)
        let topInset: CGFloat = screen.safeAreaInsets.top <= 0 ? 4 : 0
        panel.setFrame(NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height - topInset,
            width: size.width,
            height: size.height
        ), display: true)
        syncHostingViewToPanel()
    }

    private func notchSize(expanded: Bool, on screen: NSScreen? = nil) -> NSSize {
        let size = model.presentationSize
        return NSSize(width: size.width, height: size.height)
    }

    private func panelSize(expanded: Bool, on screen: NSScreen? = nil) -> NSSize {
        guard let screen = screen ?? preferences.targetScreen() else {
            return NSSize(width: 450, height: 138)
        }
        let visibleSize = notchSize(expanded: expanded, on: screen)
        guard screen.safeAreaInsets.top > 0 else { return visibleSize }
        // Keep every standard presentation inside one fixed top-anchored canvas.
        // Resizing the AppKit panel when settings opens can briefly expose the
        // desktop between the physical notch and the SwiftUI surface.
        let taskListCanvasHeight = model.activeTasks.count > 1
            ? max(174, 80 + CGFloat(model.activeTasks.count * 40))
            : 174
        return NSSize(
            width: max(450, visibleSize.width),
            height: max(taskListCanvasHeight, visibleSize.height)
        )
    }

    private func resizeForCurrentState() {
        guard let panel, let screen = preferences.targetScreen() else { return }
        let newSize = panelSize(expanded: model.isExpanded, on: screen)
        let topInset: CGFloat = screen.safeAreaInsets.top <= 0 ? 4 : 0
        let frame = NSRect(
            x: screen.frame.midX - newSize.width / 2,
            y: screen.frame.maxY - newSize.height - topInset,
            width: newSize.width,
            height: newSize.height
        )
        guard !panel.frame.equalTo(frame) else { return }
        pendingResizeTask?.cancel()
        if newSize.height < panel.frame.height {
            pendingResizeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                self?.applyCurrentFrame()
            }
            return
        }
        // Keep the physical top edge pixel-locked. Animating the panel origin and
        // height together can expose a one-frame seam below the camera housing.
        panel.setFrame(frame, display: true)
        syncHostingViewToPanel()
    }

    private func applyCurrentFrame() {
        guard let panel, let screen = preferences.targetScreen() else { return }
        let size = panelSize(expanded: model.isExpanded, on: screen)
        let topInset: CGFloat = screen.safeAreaInsets.top <= 0 ? 4 : 0
        panel.setFrame(NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height - topInset,
            width: size.width,
            height: size.height
        ), display: true)
        syncHostingViewToPanel()
    }

    private func syncHostingViewToPanel() {
        guard let panel, let hostingView else { return }
        hostingView.frame = NSRect(origin: .zero, size: panel.frame.size)
        hostingView.needsLayout = true
        hostingView.layoutSubtreeIfNeeded()
    }

    func windowDidResignKey(_ notification: Notification) { model.collapse() }
}

final class NotchPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
