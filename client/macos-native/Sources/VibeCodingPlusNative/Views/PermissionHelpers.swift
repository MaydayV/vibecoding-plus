import SwiftUI
import EventKit
func micPermissionGranted() -> Bool {
    MicrophonePermission.isGranted
}

func reminderPermissionGranted() -> Bool {
    let status = EKEventStore.authorizationStatus(for: .reminder)
    return status == .authorized || status == .fullAccess || status == .writeOnly
}
