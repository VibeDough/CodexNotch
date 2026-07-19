import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: NotchPanel?
    private var hostingView: NSHostingView<NotchView>?
    private var environmentTimer: Timer?
    private var hoverTimer: Timer?
    private var pendingResizeTask: Task<Void, Never>?
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
        panel.onEscape = { [weak self] in self?.model.collapse() }
        self.hostingView = hostingView
        self.panel = panel
    }

    private func refreshPresentation(reposition: Bool) {
        guard let panel, let screen = preferences.targetScreen() else { return }
        model.setCompactBar(screen.safeAreaInsets.top <= 0)
        let conflict = !NSRunningApplication.runningApplications(
            withBundleIdentifier: "theboringteam.boringnotch"
        ).isEmpty
        let fullscreen = hasFullscreenWindow(on: screen)
        let hasImportantStatus = model.activeTaskCount > 0 || model.visibleCompletionMessage != nil
        let hiddenByConflict = preferences.coexistenceMode == .menuBarOnly
            || (preferences.coexistenceMode == .automatic && conflict)
        let hiddenByFullscreen = fullscreen && !hasImportantStatus

        if hiddenByConflict || hiddenByFullscreen {
            panel.orderOut(nil)
        } else {
            if reposition || !panel.isVisible {
                position(panel, on: screen)
            }
            panel.orderFrontRegardless()
        }
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
        guard let screen = screen ?? preferences.targetScreen() else {
            return expanded ? NSSize(width: 360, height: 126) : NSSize(width: 205, height: 44)
        }
        if expanded { return NSSize(width: 450, height: 126) }
        if model.isShowingSettings { return NSSize(width: 450, height: 138) }
        if model.waitingTask != nil { return NSSize(width: 450, height: 94) }
        if model.visibleCompletionMessage != nil, model.completedTask != nil {
            return NSSize(width: 450, height: 86)
        }
        if model.isTaskStatusPinned, model.activeTasks.count > 1 {
            return NSSize(width: 450, height: 80 + CGFloat(model.activeTasks.count * 40))
        }
        if model.primaryTask != nil {
            return NSSize(width: 450, height: 86)
        }
        if model.isHovered { return NSSize(width: 450, height: 112) }
        if screen.safeAreaInsets.top <= 0 {
            return NSSize(width: 270, height: model.visibleCompletionMessage == nil ? 36 : 80)
        }
        return NSSize(width: 310, height: 38)
    }

    private func panelSize(expanded: Bool, on screen: NSScreen? = nil) -> NSSize {
        guard let screen = screen ?? preferences.targetScreen() else {
            return NSSize(width: 450, height: 112)
        }
        let usesHoverCanvas = screen.safeAreaInsets.top > 0
            && !expanded
            && !model.isShowingSettings
            && model.waitingTask == nil
            && model.visibleCompletionMessage == nil
            && model.activeTasks.isEmpty
        return usesHoverCanvas
            ? NSSize(width: 450, height: 112)
            : notchSize(expanded: expanded, on: screen)
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
