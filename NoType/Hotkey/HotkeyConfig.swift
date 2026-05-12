import Foundation

enum HotkeyBinding: Equatable, Sendable {
    case rightOption
}

struct HotkeyConfig: Sendable {
    static let `default` = HotkeyConfig(binding: .rightOption)
    var binding: HotkeyBinding
}
