import AppKit

struct DockWindowTraits: Equatable {
    var isPanel: Bool
    var isNormalLevel: Bool
    var hasTitlebar: Bool
    var isStatusBarWindow: Bool
    var isVisible: Bool
    var isMiniaturized: Bool
    var isKey: Bool
    var isMain: Bool
    var title: String
    var area: Double
}

struct DockRaisePlan: Equatable {
    var orderFront: [Int]
    var deminiaturize: [Int]
}

enum DockActivationPolicy {
    /// Dock clicks should surface real app windows. Status items, panels, and
    /// empty helper windows are ignored so they cannot steal key focus.
    static func plan(for windows: [DockWindowTraits]) -> DockRaisePlan {
        let strict = indices(in: windows, where: isForegroundWindow)
        let chosen = strict.isEmpty ? indices(in: windows, where: isFallbackWindow) : strict
        let ordered = chosen.sorted { rank(windows[$0]) < rank(windows[$1]) }
        let anyVisible = ordered.contains { index in
            let window = windows[index]
            return window.isVisible && !window.isMiniaturized
        }
        let deminiaturize = ordered.filter { windows[$0].isMiniaturized && !anyVisible }
        let orderFront = ordered.filter { index in
            let window = windows[index]
            return !window.isMiniaturized || !anyVisible
        }
        return DockRaisePlan(orderFront: orderFront, deminiaturize: deminiaturize)
    }

    private static func indices(in windows: [DockWindowTraits], where include: (DockWindowTraits) -> Bool) -> [Int] {
        windows.enumerated().compactMap { include($0.element) ? $0.offset : nil }
    }

    private static func isForegroundWindow(_ window: DockWindowTraits) -> Bool {
        guard window.isNormalLevel, !window.isPanel, window.hasTitlebar, !window.isStatusBarWindow else {
            return false
        }
        guard window.isVisible || window.isMiniaturized || window.title == "跃界" else { return false }
        if window.isMiniaturized { return true }
        if !window.title.isEmpty { return true }
        return window.area > 4
    }

    private static func isFallbackWindow(_ window: DockWindowTraits) -> Bool {
        guard window.isNormalLevel, !window.isStatusBarWindow else { return false }
        guard window.isVisible || window.isMiniaturized || window.title == "跃界" else { return false }
        return window.isMiniaturized || !window.title.isEmpty
    }

    /// Higher rank is ordered last and becomes the key window.
    private static func rank(_ window: DockWindowTraits) -> Int {
        var rank = 0
        if window.isKey { rank += 1_000 }
        if window.isMain { rank += 100 }
        if window.isVisible && !window.isMiniaturized { rank += 10 }
        if window.title == "跃界" { rank += 5 }
        rank += min(Int(window.area / 10_000), 4)
        return rank
    }
}

extension DockWindowTraits {
    init(_ window: NSWindow) {
        let className = NSStringFromClass(type(of: window))
        isPanel = window is NSPanel
        isNormalLevel = window.level == .normal
        hasTitlebar = window.styleMask.contains(.titled)
        isStatusBarWindow = className.contains("StatusBar")
        isVisible = window.isVisible
        isMiniaturized = window.isMiniaturized
        isKey = window.isKeyWindow
        isMain = window.isMainWindow
        title = window.title
        area = Double(window.frame.width * window.frame.height)
    }
}

/// Uses AppKit's standard reopen callback and completes window ordering after
/// application activation, so a Dock click also works while already active.
@MainActor
enum DockReopen {
    private static var revealPending = false
    private static var activationObserver: NSObjectProtocol?

    static func start() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                applicationDidBecomeActive()
            }
        }
    }

    private static func activateApplication() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }

    static func applicationDidBecomeActive() {
        trace("didBecomeActive")
        if revealPending {
            finishPendingReveal()
        } else if NSApp.isActive {
            _ = raiseExistingWindows(moveToActiveSpace: true)
        }
        // Finish ordering after AppKit/SwiftUI's own activation processing.
        DispatchQueue.main.async {
            guard NSApp.isActive else { return }
            _ = raiseExistingWindows(moveToActiveSpace: true)
        }
    }

    static func handleDockClick() {
        trace("reopen")
        start()
        revealPending = true
        activateApplication()
        finishPendingReveal()
        if revealPending {
            DispatchQueue.main.async {
                guard revealPending else { return }
                activateApplication()
                finishPendingReveal()
            }
        }
    }

    static func finishPendingReveal() {
        guard revealPending else { return }
        if NSApp.isActive {
            revealPending = false
        }
        let raised = raiseExistingWindows(moveToActiveSpace: true)
        if !raised {
            MainWindowActivation.openMainWindow()
            NotificationCenter.default.post(name: MainWindowActivation.revealNotification, object: nil)
        }
        // SwiftUI may create or order the scene on the next main run-loop iteration.
        DispatchQueue.main.async {
            guard NSApp.isActive else { return }
            _ = raiseExistingWindows(moveToActiveSpace: true)
        }
    }

    private static func trace(_ stage: String) {
        let windows = NSApp.windows.map {
            "id=\($0.windowNumber),level=\($0.level.rawValue),panel=\($0 is NSPanel),titled=\($0.styleMask.contains(.titled)),visible=\($0.isVisible),isKey:\($0.isKeyWindow),isMain:\($0.isMainWindow)"
        }.joined(separator: "; ")
        AppLogger.shared.debug("WindowActivation stage=\(stage) active=\(NSApp.isActive) hidden=\(NSApp.isHidden) windows=[\(windows)]")
    }

    @discardableResult
    static func raiseExistingWindows(moveToActiveSpace: Bool) -> Bool {
        let windows = NSApp.windows
        let plan = DockActivationPolicy.plan(for: windows.map(DockWindowTraits.init))
        trace("raise candidates=\(plan.orderFront.count)")
        guard !plan.orderFront.isEmpty else { return false }
        activateApplication()
        for index in plan.deminiaturize where windows.indices.contains(index) {
            windows[index].deminiaturize(nil)
        }
        for index in plan.orderFront where windows.indices.contains(index) {
            let window = windows[index]
            if moveToActiveSpace {
                window.collectionBehavior.insert(.moveToActiveSpace)
            }
            window.orderFrontRegardless()
        }
        if let keyIndex = plan.orderFront.last, windows.indices.contains(keyIndex) {
            windows[keyIndex].makeKeyAndOrderFront(nil)
        }
        trace("raised")
        return true
    }
}

/// Live status-item updates while a menu is tracking clear the row under the pointer.
struct StatusMenuLiveUpdate: Equatable {
    private(set) var menuOpen = false
    private var chromePending = false

    mutating func willOpenMenu() {
        menuOpen = true
    }

    /// False means keep the status button as it is until the menu closes.
    mutating func consumeChromeUpdate() -> Bool {
        if menuOpen {
            chromePending = true
            return false
        }
        return true
    }

    /// True when a chrome change arrived while the menu was open.
    mutating func didCloseMenu() -> Bool {
        menuOpen = false
        let apply = chromePending
        chromePending = false
        return apply
    }
}

@MainActor
enum MainWindowActivation {
    static let sceneID = "main"
    static let revealNotification = Notification.Name("hopWorldRevealMainWindow")
    static var openMainWindow: () -> Void = {}
}
