import AppKit

/// The outline remains transparent to input; a scoped event tap handles the finishing click.
@MainActor
final class ScrollCaptureOutline: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(selection: CGRect) {
        super.init(contentRect: selection.insetBy(dx: -2, dy: -2), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let border = NSView(frame: CGRect(origin: .zero, size: frame.size))
        border.wantsLayer = true
        border.layer?.borderColor = NSColor.controlAccentColor.cgColor
        border.layer?.borderWidth = 2
        contentView = border
    }
}
