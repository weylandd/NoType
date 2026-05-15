import AVFoundation
import AppKit
import Foundation

enum MicrophonePermission {
    static func current() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:               return .granted
        case .denied, .restricted:      return .denied
        case .notDetermined:            return .notDetermined
        @unknown default:               return .unknown
        }
    }

    static func request() async -> PermissionStatus {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .granted : .denied
    }

    static func openSystemSettings() {
        SystemSettingsPane.microphone.open()
    }
}
