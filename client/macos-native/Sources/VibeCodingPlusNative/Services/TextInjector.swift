import AppKit
import ApplicationServices
import Foundation

// MARK: - Text Injection Mode

enum TextInjectionMode: String {
    case typeAndEnter = "type_and_enter"
    case typeOnly = "type_only"
}

// MARK: - Text Injector Errors

enum TextInjectorError: LocalizedError {
    case accessibilityNotTrusted
    case eventCreationFailed(String)
    case appleScriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            "辅助功能未生效。请到「系统设置 → 隐私与安全性 → 辅助功能」删除旧的 VibeCoding Plus 条目，用 + 重新添加：\(AccessibilitySupport.runningAppPath)"
        case .eventCreationFailed(let detail):
            "键盘事件创建失败: \(detail)"
        case .appleScriptFailed(let detail):
            "AppleScript 注入失败: \(detail)"
        }
    }
}

// MARK: - Text Injector

enum TextInjector {
    private static let queue = DispatchQueue(label: "com.vibecoding.text-injector")

    static func inject(
        _ text: String,
        mode: TextInjectionMode = .typeAndEnter,
        dryRun: Bool = false
    ) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if dryRun {
            InjectLogger.log("dry-run inject mode=\(mode.rawValue) text=\(trimmed.prefix(80))")
            return
        }

        logPreflight(action: "inject", extra: "mode=\(mode.rawValue) len=\(trimmed.count)")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try injectOnQueue(trimmed, mode: mode)
                    InjectLogger.log("inject ok via primary path")
                    continuation.resume()
                } catch {
                    InjectLogger.log("inject failed: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func undoLastInput(length: Int) async throws {
        guard length > 0 else { return }
        logPreflight(action: "undo", extra: "len=\(length)")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try undoOnQueue(length)
                    continuation.resume()
                } catch {
                    InjectLogger.log("undo failed: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Extended grapheme clusters to send as Backspace (key code 51) events.
    /// Matches Swift `String.count`; may differ from some apps' word-boundary undo.
    static func backspaceSteps(for text: String) -> Int {
        text.count
    }

    static func pressReturn(dryRun: Bool = false) async throws {
        if dryRun {
            InjectLogger.log("dry-run return")
            return
        }
        logPreflight(action: "return", extra: "")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    prepareFocusedTarget()
                    try runAppleScript(returnScript(shouldPaste: false))
                    InjectLogger.log("return ok")
                    continuation.resume()
                } catch {
                    InjectLogger.log("return failed: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func clearInput(dryRun: Bool = false) async throws {
        if dryRun {
            InjectLogger.log("dry-run clear")
            return
        }
        logPreflight(action: "clear", extra: "")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    prepareFocusedTarget()
                    try runAppleScript(clearScript)
                    InjectLogger.log("clear ok")
                    continuation.resume()
                } catch {
                    InjectLogger.log("clear failed: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Private

    private static func injectOnQueue(_ text: String, mode: TextInjectionMode) throws {
        try checkAccessibility(prompt: false)
        prepareFocusedTarget()

        let previousClipboard = NSPasteboard.general.string(forType: .string)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Thread.sleep(forTimeInterval: 0.06)

        // 无论走 AppleScript 主路径还是 CGEvent 兜底路径、成功还是失败，
        // 剪贴板里都必须保持待注入文本直到粘贴动作真正完成，最后统一用
        // defer 恢复旧内容——避免兜底路径把旧剪贴板内容误粘贴出去。
        defer {
            restoreClipboard(previousClipboard)
        }

        do {
            let pressEnter = mode == .typeAndEnter
            try runAppleScript(pasteScript(pressEnter: pressEnter))
            Thread.sleep(forTimeInterval: 0.25)
        } catch {
            InjectLogger.log("AppleScript paste failed, trying CGEvent fallback")
            try injectViaCGEvent(mode: mode)
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private static func injectViaCGEvent(mode: TextInjectionMode) throws {
        try simulateKey(0x09, flags: .maskCommand)
        if mode == .typeAndEnter {
            Thread.sleep(forTimeInterval: 0.12)
            try simulateKey(0x24)
        }
    }

    private static func undoOnQueue(_ length: Int) throws {
        try checkAccessibility(prompt: false)
        prepareFocusedTarget()
        try runAppleScript(undoScript(count: length))
    }

    private static func prepareFocusedTarget() {
        let front = NSWorkspace.shared.frontmostApplication
        InjectLogger.log("frontmost=\(front?.localizedName ?? "?") bundle=\(front?.bundleIdentifier ?? "?")")

        guard front?.bundleIdentifier == Bundle.main.bundleIdentifier else { return }

        DispatchQueue.main.sync {
            NSApp.hide(nil)
        }
        Thread.sleep(forTimeInterval: 0.20)

        if let next = NSWorkspace.shared.frontmostApplication {
            InjectLogger.log("after hide frontmost=\(next.localizedName ?? "?") bundle=\(next.bundleIdentifier ?? "?")")
        }
    }

    private static func simulateKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw TextInjectorError.eventCreationFailed("CGEventSource")
        }
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw TextInjectorError.eventCreationFailed("key \(keyCode)")
        }
        if !flags.isEmpty {
            keyDown.flags = flags
            keyUp.flags = flags
        }
        // 只投递一次：.cgSessionEventTap 和 .cghidEventTap 都是真实的事件注入点，
        // 两个都投会导致按键被处理两次（双份 Cmd+V / 双回车）。这里选
        // .cghidEventTap，因为它位于事件流最上游、等价于硬件输入，
        // 作为 AppleScript 失败后的兜底路径，对大多数 App 的兼容性最好。
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private static func restoreClipboard(_ previousContent: String?) {
        NSPasteboard.general.clearContents()
        if let content = previousContent {
            NSPasteboard.general.setString(content, forType: .string)
        }
    }

    private static func checkAccessibility(prompt: Bool = false) throws {
        let trusted = AccessibilitySupport.isTrusted(prompt: prompt)
        InjectLogger.log("AX trusted=\(trusted) app=\(AccessibilitySupport.runningAppPath)")
        if !trusted { throw TextInjectorError.accessibilityNotTrusted }
    }

    private static func logPreflight(action: String, extra: String) {
        let trusted = AccessibilitySupport.isTrusted
        InjectLogger.log("preflight action=\(action) \(extra) AX=\(trusted) app=\(AccessibilitySupport.runningAppPath)")
    }

    // MARK: - AppleScript (primary — same approach as archived Node host)

    private static func escapeAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func pasteScript(pressEnter: Bool) -> String {
        """
        tell application "System Events"
          keystroke "v" using command down
          \(pressEnter ? "delay 0.12\n  key code 36" : "")
        end tell
        """
    }

    private static func returnScript(shouldPaste: Bool) -> String {
        """
        tell application "System Events"
          key code 36
        end tell
        """
    }

    private static let clearScript = """
    tell application "System Events"
      keystroke "a" using command down
      delay 0.08
      key code 51
    end tell
    """

    private static func undoScript(count: Int) -> String {
        """
        tell application "System Events"
          repeat \(count) times
            key code 51
          end repeat
        end tell
        """
    }

    private static func runAppleScript(_ script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw TextInjectorError.appleScriptFailed(errText.isEmpty ? "exit \(process.terminationStatus)" : errText)
        }
    }
}
