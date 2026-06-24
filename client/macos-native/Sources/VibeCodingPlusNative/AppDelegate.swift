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
        let state = appState?.bridge.snapshot.status.label ?? "已停止"
        menu.addItem(NSMenuItem(title: "VibeCoding Plus · \(state)", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "显示窗口", action: #selector(showWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "启动服务", action: #selector(startService), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "重启服务", action: #selector(restartService), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "停止服务", action: #selector(stopService), keyEquivalent: ""))
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

    @objc private func openConfigFolder() {
        Task { @MainActor in appState?.openConfigFolder() }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
