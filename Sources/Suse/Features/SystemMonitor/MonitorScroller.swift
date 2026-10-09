import AppKit

/// Changes only painting; AppKit retains the full hit region, dragging and accessibility.
@MainActor
final class MonitorScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    private var hoverArea: NSTrackingArea?
    private(set) var isHovered = false

    var displayedKnobRect: NSRect {
        let native = rect(for: .knob)
        guard !isHovered, !native.isEmpty else { return native }
        let thickness: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 4 : 3
        if bounds.height >= bounds.width {
            return CGRect(x: native.midX - thickness / 2, y: native.minY, width: min(thickness, native.width), height: native.height)
        }
        return CGRect(x: native.minX, y: native.midY - thickness / 2, width: native.width, height: min(thickness, native.height))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); isHovered = true; needsDisplay = true }
    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event); isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); isHovered = false; needsDisplay = true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { isHovered = false } }
    override func drawKnob() {
        if isHovered { super.drawKnob(); return }
        let knob = displayedKnobRect
        guard isEnabled, !knob.isEmpty else { return }
        NSColor.secondaryLabelColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: knob, xRadius: 2, yRadius: 2).fill()
    }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        if isHovered { super.drawKnobSlot(in: slotRect, highlight: flag) }
    }

    static func install(in scroll: NSScrollView) {
        scroll.verticalScroller = MonitorScroller()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
    }
}
