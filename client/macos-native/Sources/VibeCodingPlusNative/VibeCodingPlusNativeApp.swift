import SwiftUI

@main
struct VibeCodingPlusNativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 980, minHeight: 680)
                .task {
                    appDelegate.appState = state
                    await state.bootstrap()
                    appDelegate.refreshStatusMenu()
                    registerGlobalShortcut()
                }
                .onChange(of: state.serviceRunning) { _, _ in
                    appDelegate.refreshStatusMenu()
                }
        }
        .commands {
            CommandMenu("服务") {
                Button("切换服务 ⌘⇧V") { Task { await state.toggleService() } }
                Button("启动服务") { Task { await state.startService() } }
                Button("重启服务") { Task { await state.restartService() } }
                Button("停止服务") { Task { await state.stopService() } }
                Divider()
                Button("打开配置目录") { state.openConfigFolder() }
            }
        }
    }

    private func registerGlobalShortcut() {
        // Local monitor catches the shortcut when the app is active
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains([.command, .shift]) && event.charactersIgnoringModifiers == "v" {
                Task { @MainActor in
                    await state.toggleService()
                }
                return nil
            }
            return event
        }
        // Global monitor catches the shortcut when the app is in the background
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains([.command, .shift]) && event.charactersIgnoringModifiers == "v" {
                Task { @MainActor in
                    await state.toggleService()
                }
            }
        }
    }
}
