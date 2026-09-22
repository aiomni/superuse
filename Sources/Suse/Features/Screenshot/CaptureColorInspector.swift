import AppKit
import SuseCore

/// One selection session shares its format across displays. Clipboard writes only
/// happen for the explicit copy shortcut, never while hovering or switching format.
@MainActor
final class CaptureColorInspector {
    enum Action { case formatChanged, copied, copyFailed }
    private(set) var format: CaptureColorFormat = .rgb
    private let pasteboard: NSPasteboard
    private var shiftIsDown = false

    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    func handle(_ event: NSEvent, sample: CapturePixel?) -> Action? {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.type == .flagsChanged {
            let wasDown = shiftIsDown
            shiftIsDown = modifiers.contains(.shift)
            if [56, 60].contains(event.keyCode), !wasDown, modifiers == [.shift] {
                format = format.next
                return .formatChanged
            }
        }
        guard event.type == .keyDown, event.keyCode == 8, modifiers == [.command],
              let sample else { return nil }
        pasteboard.clearContents()
        return pasteboard.setString(format.string(for: sample.color), forType: .string) ? .copied : .copyFailed
    }
}
