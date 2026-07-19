import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: NotchPanel?
    private var glowPanels: [NSPanel] = []
    private var environmentTimer: Timer?
    private var hoverTimer: Timer?
    private let model = NotchModel()
    private let preferences = AppPreferences()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installPanel()
        installGlowPanels()

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
        let initialSize = notchSize(expanded: false)
        hostingView.frame = NSRect(origin: .zero, size: initialSize)

        let panel = NotchPanel(
            contentRect: hostingView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.model.collapse() }
        self.panel = panel
    }

    private func installGlowPanels() {
        glowPanels = [true, false].map { pointsLeft in
            let hostingView = NSHostingView(rootView: NotchGlowWing(
                model: model,
                pointsOutwardToLeft: pointsLeft
            ))
            hostingView.frame = NSRect(x: 0, y: 0, width: 42, height: 6)
            let wing = NSPanel(
                contentRect: hostingView.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            wing.contentView = hostingView
            wing.isOpaque = false
            wing.backgroundColor = .clear
            wing.hasShadow = false
            wing.ignoresMouseEvents = true
            wing.level = .statusBar
            wing.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            return wing
        }
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
            glowPanels.forEach { $0.orderOut(nil) }
        } else {
            if reposition || !panel.isVisible {
                position(panel, on: screen)
            }
            panel.orderFrontRegardless()
            positionGlowPanels(on: screen)
            glowPanels.forEach { $0.orderFrontRegardless() }
        }
    }

    private func positionGlowPanels(on screen: NSScreen) {
        guard glowPanels.count == 2 else { return }
        let bodyWidth: CGFloat = 450
        let wingWidth: CGFloat = 42
        let bodyLeft = screen.frame.midX - bodyWidth / 2
        let y = screen.frame.maxY - 6
        let overlap: CGFloat = 0.5
        glowPanels[0].setFrame(NSRect(x: bodyLeft - wingWidth + overlap, y: y, width: wingWidth, height: 6), display: true)
        glowPanels[1].setFrame(NSRect(x: bodyLeft + bodyWidth - overlap, y: y, width: wingWidth, height: 6), display: true)
    }

    private func refreshPointerHover() {
        guard let panel, panel.isVisible else {
            model.setHovered(false)
            return
        }
        let hitArea = panel.frame.insetBy(dx: -10, dy: -8)
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
        let size = notchSize(expanded: model.isExpanded, on: screen)
        let topInset: CGFloat = screen.safeAreaInsets.top <= 0 ? 4 : 0
        panel.setFrame(NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height - topInset,
            width: size.width,
            height: size.height
        ), display: true)
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
        if model.isTaskStatusPinned, !model.activeTasks.isEmpty {
            return NSSize(width: 450, height: 80 + CGFloat(model.activeTasks.count * 40))
        }
        if model.primaryTask != nil {
            return NSSize(width: 450, height: 86)
        }
        if model.isHovered { return NSSize(width: 450, height: 112) }
        if screen.safeAreaInsets.top <= 0 {
            return NSSize(width: 270, height: model.visibleCompletionMessage == nil ? 36 : 80)
        }
        return NSSize(
            width: 450,
            height: model.visibleCompletionMessage == nil ? 44 : 88
        )
    }

    private func resizeForCurrentState() {
        guard let panel, let screen = preferences.targetScreen() else { return }
        let newSize = notchSize(expanded: model.isExpanded, on: screen)
        let topInset: CGFloat = screen.safeAreaInsets.top <= 0 ? 4 : 0
        let frame = NSRect(
            x: screen.frame.midX - newSize.width / 2,
            y: screen.frame.maxY - newSize.height - topInset,
            width: newSize.width,
            height: newSize.height
        )
        guard !panel.frame.equalTo(frame) else { return }
        // Keep the physical top edge pixel-locked. Animating the panel origin and
        // height together can expose a one-frame seam below the camera housing.
        panel.setFrame(frame, display: true)
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
