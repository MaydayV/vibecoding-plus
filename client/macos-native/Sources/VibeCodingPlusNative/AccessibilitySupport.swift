import AppKit
import ApplicationServices
import Foundation

/// Helpers for macOS Accessibility (TCC) trust checks and user guidance.
enum AccessibilitySupport {
    /// Path of the currently running `.app` bundle.
    static var runningAppPath: String {
        Bundle.main.bundleURL.path
    }

    /// Whether this process is trusted for Accessibility (no system prompt).
    static var isTrusted: Bool {
        isTrusted(prompt: false)
    }

    static func isTrusted(prompt: Bool) -> Bool {
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    /// Reveal the running app in Finder so the user can drag it into System Settings.
    static func revealRunningAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    static func openAccessibilitySettings() {
        if #available(macOS 13.0, *) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
                return
            }
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Shown when TCC toggle may be ON for an older build path/signature but this binary is untrusted.
    static var reauthorizeHint: String {
        """
        若系统设置里已开启但仍无法输入，通常是重新编译/安装后签名变化导致授权失效。请：
        1. 在辅助功能列表中删除所有「VibeCoding Plus」旧条目
        2. 点「在 Finder 中显示」定位当前应用
        3. 在辅助功能中点 + 重新添加该 .app（建议安装到「应用程序」文件夹后授权）
        """
    }
}
