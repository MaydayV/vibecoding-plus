import Foundation
import AppKit
#if canImport(AVFoundation)
import AVFoundation
#endif

enum MicrophonePermission {
    static var isGranted: Bool {
        #if canImport(AVFoundation)
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        #else
        return false
        #endif
    }

    static var statusText: String {
        #if canImport(AVFoundation)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "已授权"
        case .notDetermined: return "未请求"
        case .denied: return "已拒绝"
        case .restricted: return "受限制"
        @unknown default: return "未知"
        }
        #else
        return "不可用"
        #endif
    }

    static func requestIfNeeded() async -> Bool {
        #if canImport(AVFoundation)
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized { return true }
        guard status == .notDetermined else { return false }

        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        #else
        return false
        #endif
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
