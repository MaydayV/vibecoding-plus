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
                }
                .onChange(of: state.bridge.snapshot.status) { _, _ in
                    appDelegate.refreshStatusMenu()
                }
        }
        .commands {
            CommandMenu("服务") {
                Button("启动服务") { Task { await state.startService() } }
                Button("重启服务") { Task { await state.restartService() } }
                Button("停止服务") { Task { await state.stopService() } }
                Divider()
                Button("打开配置目录") { state.openConfigFolder() }
            }
        }
    }
}
