import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    weak var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        configureWindows()
        createStatusItem()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func refreshStatusMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        let state = (appState?.serviceRunning == true) ? "运行中" : "已停止"
        let mode = appState?.config.sendTarget.label ?? ""

        menu.addItem(NSMenuItem(title: "VibeCoding Plus · \(state) · \(mode)", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "显示窗口", action: #selector(showWindow), keyEquivalent: ""))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "启动服务", action: #selector(startService), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "重启服务", action: #selector(restartService), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "停止服务", action: #selector(stopService), keyEquivalent: ""))

        // Mode submenu
        menu.addItem(.separator())
        let modeItem = NSMenuItem(title: "模式", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for target in SendTarget.allCases {
            let item = NSMenuItem(title: target.label, action: #selector(setMode(_:)), keyEquivalent: "")
            item.representedObject = target.rawValue
            item.state = appState?.config.sendTarget == target ? .on : .off
            modeMenu.addItem(item)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        // Settings toggles
        menu.addItem(.separator())
        let launchItem = NSMenuItem(title: "开机启动", action: #selector(toggleAutoLaunch), keyEquivalent: "")
        launchItem.state = appState?.desktopSettings.autoLaunch == true ? .on : .off
        menu.addItem(launchItem)

        let hiddenItem = NSMenuItem(title: "启动时隐藏", action: #selector(toggleLaunchToTray), keyEquivalent: "")
        hiddenItem.state = appState?.desktopSettings.launchToTray == true ? .on : .off
        menu.addItem(hiddenItem)

        let closeToTrayItem = NSMenuItem(title: "关闭时最小化", action: #selector(toggleCloseToTray), keyEquivalent: "")
        closeToTrayItem.state = appState?.desktopSettings.closeToTray == true ? .on : .off
        menu.addItem(closeToTrayItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "打开配置目录", action: #selector(openConfigFolder), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func configureWindows() {
        DispatchQueue.main.async {
            for window in NSApp.windows {
                window.title = "VibeCoding Plus"
                window.titlebarAppearsTransparent = true
                window.toolbarStyle = .unifiedCompact
                window.isMovableByWindowBackground = true
                window.minSize = NSSize(width: 980, height: 680)
            }
        }
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.and.mic", accessibilityDescription: "VibeCoding Plus")
        statusItem = item
        refreshStatusMenu()
    }

    @objc private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
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
