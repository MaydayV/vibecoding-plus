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

    var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            "Accessibility permission required. Grant access in System Settings > Privacy & Security > Accessibility."
        case .eventCreationFailed(let detail):
            "Failed to create CGEvent: \(detail)"
        }
    }
}

// MARK: - Text Injector

enum TextInjector {
    /// Serial queue for all CGEvent operations — CGEvent is not thread-safe.
    private static let queue = DispatchQueue(label: "com.vibecoding.text-injector")

    /// Main text injection entry point.
    ///
    /// Saves the current clipboard, writes `text` to the pasteboard,
    /// simulates Cmd+V (and optionally Return), then restores the clipboard.
    static func inject(
        _ text: String,
        mode: TextInjectionMode = .typeAndEnter,
        dryRun: Bool = false
    ) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return }

        if dryRun {
            print("[inject] dry-run mode=\(mode.rawValue) text=\"\(trimmed)\"")
            return
        }

        try checkAccessibility()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try injectOnQueue(trimmed, mode: mode)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Undo the last input by simulating backspace key presses.
    static func undoLastInput(length: Int) async throws {
        guard length > 0 else { return }

        try checkAccessibility()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try undoOnQueue(length)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Private (runs on serial queue)

    private static func injectOnQueue(_ text: String, mode: TextInjectionMode) throws {
        // 1. Save current clipboard content.
        let previousClipboard = NSPasteboard.general.string(forType: .string)

        // 2. Write text to clipboard.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Thread.sleep(forTimeInterval: 0.06)

        do {
            // 3. Simulate Cmd+V.
            try simulateKey(0x09, flags: .maskCommand) // V key

            // 4. Optionally simulate Return.
            if mode == .typeAndEnter {
                Thread.sleep(forTimeInterval: 0.12)
                try simulateKey(0x24) // Return key
            }

            // 5. Brief delay then restore clipboard.
            Thread.sleep(forTimeInterval: 0.10)
            restoreClipboard(previousClipboard)
        } catch {
            // Always attempt to restore clipboard on failure.
            restoreClipboard(previousClipboard)
            throw error
        }
    }

    private static func undoOnQueue(_ length: Int) throws {
        for _ in 0..<length {
            try simulateKeyWithDelay(0x33, delayMs: 30) // Backspace key
        }
    }

    // MARK: - CGEvent Helpers

    private static func simulateKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw TextInjectorError.eventCreationFailed("Cannot create CGEventSource")
        }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw TextInjectorError.eventCreationFailed("Cannot create CGEvent for key \(keyCode)")
        }

        if !flags.isEmpty {
            keyDown.flags = flags
            keyUp.flags = flags
        }

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private static func simulateKeyWithDelay(_ keyCode: CGKeyCode, flags: CGEventFlags = [], delayMs: UInt64 = 30) throws {
        try simulateKey(keyCode, flags: flags)
        usleep(UInt32(delayMs) * 1000)
    }

    // MARK: - Clipboard

    private static func restoreClipboard(_ previousContent: String?) {
        guard let content = previousContent else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }

    // MARK: - Accessibility Check

    private static func checkAccessibility() throws {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            throw TextInjectorError.accessibilityNotTrusted
        }
    }
}
