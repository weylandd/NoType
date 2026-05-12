import Foundation

enum PermissionStatus: Equatable, Sendable {
    case unknown
    case notDetermined
    case denied
    case granted

    var isGranted: Bool { self == .granted }
}
