import AppKit
import Foundation

@MainActor
final class BridgeService: ObservableObject {
    @Published private(set) var snapshot = ServiceSnapshot()

    private var process: Process?
    private let settingsStore = SettingsStore()
    private let maxLogLines = 220

    func start(config: AppConfig) async {
        guard process == nil else { return }
        snapshot.status = .starting
        snapshot.message = "正在启动本地服务"
        snapshot.mode = config.sendTarget
        snapshot.port = config.port
        snapshot.logs.removeAll()

        guard let serverURL = locateServerEntry() else {
            snapshot.status = .error
            snapshot.message = "找不到 client/server/src/server.mjs"
            return
        }
        guard let nodeURL = locateNodeExecutable() else {
            snapshot.status = .error
            snapshot.message = "找不到内置 Node 运行时，也没有可用的系统 node"
            return
        }

        let proc = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.executableURL = nodeURL
        proc.arguments = [serverURL.path]
        proc.currentDirectoryURL = serverURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        proc.environment = Shell.environment(extra: [
            "VIBE_DESKTOP": "1",
            "VIBE_INVOKE_CWD": NSHomeDirectory(),
            "VIBECODING_NATIVE_RUNTIME": runtimeRoot()?.path ?? ""
        ])
        proc.standardOutput = stdout
        proc.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.appendLog(text, source: "bridge") }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.appendLog(text, source: "bridge") }
        }

        proc.terminationHandler = { [weak self] terminated in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self, self.process === terminated else { return }
                self.process = nil
                if self.snapshot.status != .stopped {
                    self.snapshot.status = .error
                    self.snapshot.message = "服务已退出，退出码 \(terminated.terminationStatus)"
                }
                self.snapshot.pid = nil
            }
        }

        do {
            try proc.run()
            process = proc
            snapshot.pid = proc.processIdentifier
            await waitUntilReady(port: config.port)
        } catch {
            snapshot.status = .error
            snapshot.message = error.localizedDescription
        }
    }

    func stop() async {
        guard let process else {
            snapshot.status = .stopped
            snapshot.message = "服务已停止"
            snapshot.pid = nil
            return
        }
        snapshot.message = "正在停止服务"
        self.process = nil
        process.terminate()
        try? await Task.sleep(for: .milliseconds(400))
        if process.isRunning {
            process.interrupt()
        }
        snapshot.status = .stopped
        snapshot.message = "服务已停止"
        snapshot.pid = nil
    }

    func restart(config: AppConfig) async {
        await stop()
        await start(config: config)
    }

    func openConfigFolder() {
        NSWorkspace.shared.open(settingsStore.configDirectory)
    }

    func refreshHealth(config: AppConfig) async {
        let url = URL(string: "http://127.0.0.1:\(config.port)/healthz")!
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode == 200, process != nil {
                snapshot.status = .running
                snapshot.message = "服务运行中"
            }
        } catch {
            if process != nil {
                snapshot.status = .starting
                snapshot.message = "等待服务就绪"
            }
        }
    }

    private func waitUntilReady(port: Int) async {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let url = URL(string: "http://127.0.0.1:\(port)/healthz")!
            if let (_, response) = try? await URLSession.shared.data(from: url),
               let http = response as? HTTPURLResponse,
               http.statusCode == 200 {
                snapshot.status = .running
                snapshot.message = "服务运行中"
                return
            }
            try? await Task.sleep(for: .milliseconds(350))
        }
        snapshot.status = .error
        snapshot.message = "服务启动超时"
    }

    private func appendLog(_ text: String, source: String) {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { "[\(source)] \(String($0))" }
        snapshot.logs.append(contentsOf: lines)
        if snapshot.logs.count > maxLogLines {
            snapshot.logs.removeFirst(snapshot.logs.count - maxLogLines)
        }
    }

    private func locateServerEntry() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let envRoot = ProcessInfo.processInfo.environment["VIBE_REPO_ROOT"], !envRoot.isEmpty {
            candidates.append(URL(fileURLWithPath: envRoot))
        }
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath))
        candidates.append(URL(fileURLWithPath: "/Users/colin/Dev/vibecoding-plus"))
        if let runtime = runtimeRoot() {
            let server = runtime.appendingPathComponent("client/server/src/server.mjs")
            if fm.fileExists(atPath: server.path) {
                return server
            }
        }

        for root in candidates {
            let server = root.appendingPathComponent("client/server/src/server.mjs")
            if fm.fileExists(atPath: server.path) {
                return server
            }
        }
        return nil
    }

    private func locateNodeExecutable() -> URL? {
        let fm = FileManager.default
        if let runtime = runtimeRoot() {
            let bundled = runtime.appendingPathComponent("node/bin/node")
            if fm.isExecutableFile(atPath: bundled.path) {
                return bundled
            }
        }
        let systemNode = Shell.findExecutable("node")
        return systemNode.isEmpty ? nil : URL(fileURLWithPath: systemNode)
    }

    private func runtimeRoot() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let runtime = resourceURL.appendingPathComponent("runtime", isDirectory: true)
        return FileManager.default.fileExists(atPath: runtime.path) ? runtime : nil
    }
}
