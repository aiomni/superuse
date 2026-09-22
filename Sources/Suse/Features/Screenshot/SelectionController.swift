import AppKit
import SuseCore

@MainActor
struct CaptureSelection {
    let target: CaptureTarget
    let snapshot: ScreenSnapshot
}

@MainActor
final class SelectionWindow: NSWindow {
    var onCancel: (() -> Void)?
    var handleReviewKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func sendEvent(_ event: NSEvent) {
        if handleScreenshotKey(event) { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard acceptsScreenshotKeys else { return false }
        if handleScreenshotKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        guard attachedSheet == nil else { return }
        onCancel?()
    }

    private var acceptsScreenshotKeys: Bool {
        attachedSheet == nil && !(firstResponder is NSTextView)
    }

    private func handleScreenshotKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, acceptsScreenshotKeys else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53 && modifiers.isEmpty {
            onCancel?()
            return true
        }
        return handleReviewKey?(event) ?? false
    }
}

/// Keeps the original display snapshots on screen through selection and review.
/// Only live scrolling temporarily hides the frozen overlays.
@MainActor
final class SelectionController {
    private var overlays: [SelectionWindow] = []
    private var selectionCompletion: CheckedContinuation<CaptureSelection?, Never>?
    private var reviewCompletion: CheckedContinuation<CaptureReviewAction, Never>?
    private var reviewController: CaptureReviewController?

    func select(snapshots: [ScreenSnapshot], windows: [CaptureWindow]) async -> CaptureSelection? {
        close()
        return await withCheckedContinuation { continuation in
            selectionCompletion = continuation
            for snapshot in snapshots {
                let window = SelectionWindow(contentRect: snapshot.appKitFrame, styleMask: .borderless,
                                             backing: .buffered, defer: false)
                window.level = .screenSaver
                window.isOpaque = true
                window.hasShadow = false
                window.acceptsMouseMovedEvents = true
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                window.onCancel = { [weak self] in self?.cancel() }
                let view = SelectionView(image: snapshot.image, displayFrame: snapshot.display.frame, windows: windows)
                view.onSelect = { [weak self] target in
                    self?.confirm(CaptureSelection(target: target, snapshot: snapshot))
                }
                window.contentView = view
                overlays.append(window)
                window.orderFrontRegardless()
            }
            let active = overlays.first { $0.frame.contains(NSEvent.mouseLocation) } ?? overlays.first
            active?.makeKey()
            NSApp.activate()
        }
    }

    private func confirm(_ selection: CaptureSelection) {
        overlays.forEach { ($0.contentView as? SelectionView)?.freeze() }
        let completion = selectionCompletion
        selectionCompletion = nil
        completion?.resume(returning: selection)
    }

    func review(image: CGImage, selection: CaptureSelection, allowsScrolling: Bool,
                copyAutomatically: Bool) async -> CaptureReviewAction {
        guard let window = overlays.first(where: { $0.frame == selection.snapshot.appKitFrame }),
              let view = window.contentView as? SelectionView else { return .done }
        let rect = selection.target.rect.offsetBy(dx: -selection.snapshot.display.frame.minX,
                                                 dy: -selection.snapshot.display.frame.minY)
        let controller = CaptureReviewController(image: image, selectionRect: rect,
                                                 displaySize: view.bounds.size, allowsScrolling: allowsScrolling)
        reviewController = controller
        window.handleReviewKey = { [weak controller] in
            controller?.view.performKeyEquivalent(with: $0) ?? false
        }
        controller.onAction = { [weak self] action in
            guard let self else { return }
            let completion = reviewCompletion
            reviewCompletion = nil
            completion?.resume(returning: action)
        }
        view.showReview(controller.view)
        overlays.forEach { $0.orderFrontRegardless() }
        window.makeKey()
        window.makeFirstResponder(controller.view)
        NSApp.activate()
        if copyAutomatically { controller.copyImage(completing: false) }
        return await withCheckedContinuation { reviewCompletion = $0 }
    }

    func suspend() { overlays.forEach { $0.orderOut(nil) } }

    func cancel() {
        selectionCompletion?.resume(returning: nil)
        selectionCompletion = nil
        reviewCompletion?.resume(returning: .done)
        reviewCompletion = nil
        close()
    }

    func close() {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        reviewController = nil
    }
}

@MainActor
final class SelectionView: NSView {
    private let image: NSImage
    private let displayFrame: CGRect
    private var state: CaptureSelectionState
    private var frozen = false
    private var highlighted = false
    private var review: NSView?
    private var tracking: NSTrackingArea?
    var onSelect: ((CaptureTarget) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    init(image: CGImage, displayFrame: CGRect, windows: [CaptureWindow]) {
        self.image = NSImage(cgImage: image, size: displayFrame.size)
        self.displayFrame = displayFrame
        state = CaptureSelectionState(displayFrame: displayFrame, windows: windows)
        super.init(frame: CGRect(origin: .zero, size: displayFrame.size))
        setAccessibilityLabel("截图选区。单击截取自动框选的屏幕或窗口；拖动选择区域；Escape 取消。")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
        updateHover()
    }

    override func resetCursorRects() {
        if !frozen { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    func freeze() {
        frozen = true
        highlighted = state.isConfirmed
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func showReview(_ view: NSView) {
        review?.removeFromSuperview()
        review = view
        view.frame = bounds
        addSubview(view)
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) { updateHover() }
    override func mouseMoved(with event: NSEvent) { updateHover() }
    override func mouseExited(with event: NSEvent) {
        guard !frozen else { return }
        highlighted = false
        needsDisplay = true
    }

    private func updateHover() {
        guard !frozen, let window else { return }
        let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let local = convert(point, from: nil)
        highlighted = bounds.contains(local)
        state.hover(at: quartzPoint(local))
        needsDisplay = true
    }

    private func quartzPoint(_ local: CGPoint) -> CGPoint {
        CGPoint(x: local.x + displayFrame.minX, y: local.y + displayFrame.minY)
    }

    override func mouseDown(with event: NSEvent) {
        guard !frozen else { return }
        window?.makeKey()
        state.mouseDown(at: quartzPoint(convert(event.locationInWindow, from: nil)))
        highlighted = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !frozen else { return }
        state.mouseDragged(to: quartzPoint(convert(event.locationInWindow, from: nil)))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !frozen else { return }
        if let target = state.mouseUp(at: quartzPoint(convert(event.locationInWindow, from: nil))) {
            onSelect?(target)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        let selection = state.target.rect.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
        let shade = NSBezierPath(rect: bounds)
        if highlighted { shade.appendRect(selection) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill()
        shade.fill()
        if highlighted {
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(rect: selection.insetBy(dx: 1, dy: 1))
            outline.lineWidth = 2
            outline.stroke()
        }
        guard !frozen, highlighted else { return }
        let kind: String
        switch state.target.kind {
        case .display: kind = "全屏"
        case .window: kind = "窗口"
        case .region: kind = "区域"
        }
        let help = "\(kind) · 单击确认 · 拖动框选区域 · Esc 取消"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
        let size = (help as NSString).size(withAttributes: attributes)
        let helpRect = CGRect(x: (bounds.width - size.width) / 2 - 16, y: 32, width: size.width + 32, height: 36)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: helpRect, xRadius: 18, yRadius: 18).fill()
        (help as NSString).draw(at: CGPoint(x: helpRect.minX + 16, y: helpRect.minY + 10), withAttributes: attributes)
    }
}
