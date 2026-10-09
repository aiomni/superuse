import AppKit
import SuseCore

/// Passes drawing and toolbar clicks through, intercepting only crop adjustment gestures.
@MainActor
final class CaptureRegionAdjustmentView: NSView {
    var selectionRect: CGRect { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var allowsMove = true { didSet { window?.invalidateCursorRects(for: self) } }
    var onChange: ((CGRect, Bool) -> Void)?
    private var gesture: CaptureRegionAdjustment?
    private var gestureChanged = false
    override var isFlipped: Bool { true }

    init(rect: CGRect, displaySize: CGSize) {
        selectionRect = rect
        super.init(frame: CGRect(origin: .zero, size: displaySize))
        setAccessibilityLabel("调整截图区域")
        setAccessibilityHelp("拖动内部移动选区，拖动边缘或四角调整宽高；选择标注工具开始编辑。")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func handleRect(_ handle: CaptureRegionHandle) -> CGRect {
        let point = handle.point(in: selectionRect)
        // Keep visible handles and their hit targets reachable at the display boundary.
        let x = min(max(point.x, bounds.minX + 4), bounds.maxX - 4)
        let y = min(max(point.y, bounds.minY + 4), bounds.maxY - 4)
        return CGRect(x: x - 6, y: y - 6, width: 12, height: 12)
    }

    private func edgeRect(_ handle: CaptureRegionHandle) -> CGRect {
        switch handle {
        case .top: CGRect(x: selectionRect.minX, y: selectionRect.minY - 5, width: selectionRect.width, height: 10)
        case .bottom: CGRect(x: selectionRect.minX, y: selectionRect.maxY - 5, width: selectionRect.width, height: 10)
        case .left: CGRect(x: selectionRect.minX - 5, y: selectionRect.minY, width: 10, height: selectionRect.height)
        case .right: CGRect(x: selectionRect.maxX - 5, y: selectionRect.minY, width: 10, height: selectionRect.height)
        default: handleRect(handle)
        }
    }

    private func handle(at point: CGPoint) -> CaptureRegionHandle? {
        if let nearest = CaptureRegionHandle.allCases.filter({ handleRect($0).contains(point) }).min(by: {
            let a = $0.point(in: selectionRect), b = $1.point(in: selectionRect)
            return hypot(point.x - a.x, point.y - a.y) < hypot(point.x - b.x, point.y - b.y)
        }) { return nearest }
        return [.top, .right, .bottom, .left].first { edgeRect($0).contains(point) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local), handle(at: local) != nil || (allowsMove && selectionRect.contains(local)) else { return nil }
        return self
    }

    private func cursor(for handle: CaptureRegionHandle) -> NSCursor {
        switch handle {
        case .top, .bottom: .resizeUpDown
        case .left, .right: .resizeLeftRight
        default: .crosshair
        }
    }

    override func resetCursorRects() {
        guard !isHidden else { return }
        if allowsMove { addCursorRect(selectionRect, cursor: .openHand) }
        for handle in [CaptureRegionHandle.top, .right, .bottom, .left] {
            addCursorRect(edgeRect(handle).intersection(bounds), cursor: cursor(for: handle))
        }
        for handle in CaptureRegionHandle.allCases {
            addCursorRect(handleRect(handle).intersection(bounds), cursor: cursor(for: handle))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(rect: selectionRect.insetBy(dx: 1, dy: 1))
        NSColor.controlAccentColor.setStroke()
        outline.lineWidth = 2
        outline.stroke()
        for handle in CaptureRegionHandle.allCases {
            let rect = handleRect(handle).insetBy(dx: 2, dy: 2)
            let path = NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1)
            NSColor.controlBackgroundColor.setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let handle = handle(at: point)
        guard handle != nil || (allowsMove && selectionRect.contains(point)) else { return }
        window?.makeFirstResponder(self)
        gesture = CaptureRegionAdjustment(rect: selectionRect, displayFrame: bounds, start: point, handle: handle)
        gestureChanged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let gesture else { return }
        let rect = gesture.rect(at: convert(event.locationInWindow, from: nil))
        gestureChanged = gestureChanged || rect != gesture.original
        onChange?(rect, false)
    }

    override func mouseUp(with event: NSEvent) {
        guard let gesture else { return }
        self.gesture = nil
        let rect = gesture.rect(at: convert(event.locationInWindow, from: nil))
        if gestureChanged || rect != gesture.original { onChange?(rect, true) }
    }
}
