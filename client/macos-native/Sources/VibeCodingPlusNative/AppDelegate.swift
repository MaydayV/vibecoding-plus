import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    weak var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory: no Dock icon, no standard app menu bar — the app lives in
        // the menu-bar status item. LSUIElement=YES in Info.plist enforces this
        // at launch; setting it here as well makes it robust to runtime changes.
        NSApp.setActivationPolicy(.accessory)
        configureWindows()
        createStatusItem()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep the app running in the menu bar after the window is closed via
        // the red traffic-light button. The status item reopens the window.
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func refreshStatusMenu() {
        let menu = NSMenu()
        let state = (appState?.serviceRunning == true) ? "运行中" : "已停止"
        let mode = appState?.config.sendTarget.label ?? ""

        menu.addItem(NSMenuItem(title: "VibeCoding Plus · \(state) · \(mode)", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        addMenuItem(to: menu, title: "显示窗口", action: #selector(showWindow))

        menu.addItem(.separator())
        addMenuItem(to: menu, title: "启动服务", action: #selector(startService))
        addMenuItem(to: menu, title: "重启服务", action: #selector(restartService))
        addMenuItem(to: menu, title: "停止服务", action: #selector(stopService))

        // Mode submenu
        menu.addItem(.separator())
        let modeItem = NSMenuItem(title: "模式", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for target in SendTarget.allCases {
            let item = NSMenuItem(title: target.label, action: #selector(setMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target.rawValue
            item.state = appState?.config.sendTarget == target ? .on : .off
            modeMenu.addItem(item)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        // Settings toggles
        menu.addItem(.separator())
        let launchItem = addMenuItem(to: menu, title: "开机启动", action: #selector(toggleAutoLaunch))
        launchItem.state = appState?.desktopSettings.autoLaunch == true ? .on : .off

        let hiddenItem = addMenuItem(to: menu, title: "启动时隐藏", action: #selector(toggleLaunchToTray))
        hiddenItem.state = appState?.desktopSettings.launchToTray == true ? .on : .off

        let closeToTrayItem = addMenuItem(to: menu, title: "关闭时最小化", action: #selector(toggleCloseToTray))
        closeToTrayItem.state = appState?.desktopSettings.closeToTray == true ? .on : .off

        menu.addItem(.separator())
        addMenuItem(to: menu, title: "打开配置目录", action: #selector(openConfigFolder))
        menu.addItem(.separator())
        addMenuItem(to: menu, title: "退出", action: #selector(quit), keyEquivalent: "q")

        // Store the menu; do NOT assign it to statusItem.menu so that left-click
        // is delivered to our action (AppKit would otherwise swallow the click
        // to show the menu). The menu is popped manually on right/Option-click.
        statusMenu = menu
    }

    @discardableResult
    private func addMenuItem(to menu: NSMenu, title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        menu.addItem(item)
        return item
    }

    func configureWindows() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let launchToTray = self.appState?.desktopSettings.launchToTray == true
            for window in NSApp.windows where !(window is NSPanel) {
                window.title = "VibeCoding Plus"
                window.titlebarAppearsTransparent = true
                window.toolbarStyle = .unifiedCompact
                window.isMovableByWindowBackground = true
                window.minSize = NSSize(width: 980, height: 680)
                // Keep the window object alive after close so the menu-bar item
                // can re-show it; SwiftUI otherwise releases it and "显示窗口"
                // would have nothing to bring back.
                window.isReleasedWhenClosed = false
                window.delegate = self
                if launchToTray {
                    window.orderOut(nil)
                } else {
                    // .accessory apps must explicitly activate to focus the
                    // window at launch, otherwise it opens behind other apps.
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                }
            }
        }
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.and.mic", accessibilityDescription: "VibeCoding Plus")
        item.button?.image?.isTemplate = true
        // No `statusItem.menu` is assigned so that left-click is delivered to
        // our action instead of being swallowed by the menu. Left-click opens
        // the window; right-click (or Option-click) shows the status menu.
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        refreshStatusMenu()
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true {
            // Show the menu as a popover anchored to the status item button.
            if let button = statusItem?.button, let menu = statusMenu {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
            }
            return
        }
        showWindow()
    }

    @objc private func showWindow() {
        // .accessory apps need an explicit activate call to come to the front.
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { !($0 is NSPanel) }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.setIsVisible(true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        } else {
            // The retained window was ordered out (hidden) but may no longer be
            // in NSApp.windows if SwiftUI pruned it. Re-show any window we own.
            if let window = retainedWindow {
                window.setIsVisible(true)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    // MARK: - NSWindowDelegate

    /// The window we keep alive for re-showing from the menu-bar item.
    private var retainedWindow: NSWindow?

    func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, !(window is NSPanel) {
            retainedWindow = window
        }
    }

    /// Intercept the red traffic-light close. For a menu-bar accessory app the
    /// window must stay around so the status item can reopen it; otherwise
    /// SwiftUI releases it and "显示窗口" becomes a no-op. Always hide to tray.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        retainedWindow = sender
        sender.orderOut(nil)
        return false
    }

    @objc private func startService() {
        Task { @MainActor in await appState?.startService(); refreshStatusMenu() }
    }

    @objc private func restartService() {
        Task { @MainActor in await appState?.restartService(); refreshStatusMenu() }
    }

    @objc private func stopService() {
        Task { @MainActor in await appState?.stopService(); refreshStatusMenu() }
    }

    @objc private func setMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let target = SendTarget(rawValue: rawValue) else { return }
        Task { @MainActor in
            appState?.config.sendTarget = target
            await appState?.saveSettings()
            refreshStatusMenu()
        }
    }

    @objc private func toggleAutoLaunch() {
        Task { @MainActor in
            appState?.desktopSettings.autoLaunch.toggle()
            await appState?.saveSettings(restart: false)
            refreshStatusMenu()
        }
    }

    @objc private func toggleLaunchToTray() {
        Task { @MainActor in
            appState?.desktopSettings.launchToTray.toggle()
            await appState?.saveSettings(restart: false)
            refreshStatusMenu()
        }
    }

    @objc private func toggleCloseToTray() {
        Task { @MainActor in
            appState?.desktopSettings.closeToTray.toggle()
            await appState?.saveSettings(restart: false)
            refreshStatusMenu()
        }
    }

    @objc private func openConfigFolder() {
        Task { @MainActor in appState?.openConfigFolder() }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
