import Foundation

public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let control = Self(rawValue: 1 << 0)
    public static let option = Self(rawValue: 1 << 1)
    public static let shift = Self(rawValue: 1 << 2)
    public static let command = Self(rawValue: 1 << 3)
}

public struct Shortcut: Codable, Hashable, Sendable {
    public let keyCode: UInt32
    public let modifiers: ShortcutModifiers

    public init(keyCode: UInt32, modifiers: ShortcutModifiers = [.control, .option]) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var isValidGlobalShortcut: Bool {
        !modifiers.intersection([.control, .option, .command]).isEmpty
    }

    public var displayValue: String {
        let prefix = [(ShortcutModifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { modifiers.contains($0.0) }.map(\.1).joined()
        return prefix + (Self.keyNames[keyCode] ?? "Key \(keyCode)")
    }

    private static let keyNames: [UInt32: String] = [
        0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V",
        11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 18:"1", 19:"2",
        20:"3", 21:"4", 22:"6", 23:"5", 24:"=", 25:"9", 26:"7", 27:"−", 28:"8",
        29:"0", 30:"]", 31:"O", 32:"U", 33:"[", 34:"I", 35:"P", 36:"↩", 37:"L",
        38:"J", 39:"'", 40:"K", 41:";", 42:"\\", 43:",", 44:"/", 45:"N", 46:"M",
        47:".", 48:"⇥", 49:"Space", 50:"`", 51:"⌫", 53:"⎋", 65:".", 67:"*",
        69:"+", 75:"/", 76:"⌅", 78:"−", 81:"=", 82:"0", 83:"1", 84:"2", 85:"3",
        86:"4", 87:"5", 88:"6", 89:"7", 91:"8", 92:"9", 96:"F5", 97:"F6", 98:"F7",
        99:"F3", 100:"F8", 101:"F9", 103:"F11", 109:"F10", 111:"F12", 115:"↖",
        116:"⇞", 117:"⌦", 118:"F4", 119:"↘", 120:"F2", 121:"⇟", 122:"F1",
        123:"←", 124:"→", 125:"↓", 126:"↑",
    ]
}
