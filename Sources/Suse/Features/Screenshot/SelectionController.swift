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
    var handleSelectionKey: ((NSEvent) -> Bool)?
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
        guard acceptsScreenshotKeys else { return false }
        if handleSelectionKey?(event) == true { return true }
        guard event.type == .keyDown else { return false }
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
        let inspector = CaptureColorInspector()
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
                window.handleSelectionKey = { [weak self] event in
                    let active = self?.overlays.first { $0.frame.contains(NSEvent.mouseLocation) }
                    return (active?.contentView as? SelectionView)?.handleInspectionEvent(event) ?? false
                }
                let view = SelectionView(image: snapshot.image, displayFrame: snapshot.display.frame,
                                         windows: windows, inspector: inspector)
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
    private let sampler: CapturePixelSampler
    private let inspector: CaptureColorInspector
    private let loupe: CaptureLoupeView
    private var sampledPixel: CapturePixel?
    private var state: CaptureSelectionState
    private var frozen = false
    private var highlighted = false
    private var review: NSView?
    private var tracking: NSTrackingArea?
    var onSelect: ((CaptureTarget) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    init(image: CGImage, displayFrame: CGRect, windows: [CaptureWindow],
         inspector: CaptureColorInspector = CaptureColorInspector()) {
        self.image = NSImage(cgImage: image, size: displayFrame.size)
        self.displayFrame = displayFrame
        self.inspector = inspector
        sampler = CapturePixelSampler(image: image, displayFrame: displayFrame)
        loupe = CaptureLoupeView(image: image)
        state = CaptureSelectionState(displayFrame: displayFrame, windows: windows)
        super.init(frame: CGRect(origin: .zero, size: displayFrame.size))
        addSubview(loupe)
        setAccessibilityLabel("截图选区。单击确认，拖动选择区域；Shift 切换 RGB、HEX、HSL，Command C 复制色值；Escape 取消。")
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
        loupe.isHidden = true
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

    override func mouseEntered(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) {
        guard !frozen else { return }
        highlighted = false
        loupe.isHidden = true
        needsDisplay = true
    }

    private func updateHover() {
        guard !frozen, let window else { return }
        let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        updateHover(at: convert(point, from: nil))
    }

    private func updateHover(at local: CGPoint) {
        guard !frozen else { return }
        highlighted = bounds.contains(local)
        state.hover(at: quartzPoint(local))
        updateLoupe(at: local)
        needsDisplay = true
    }

    private func updateLoupe(at local: CGPoint) {
        sampledPixel = sampler.sample(at: quartzPoint(local))
        loupe.isHidden = frozen || !highlighted
        guard let sampledPixel, !loupe.isHidden else { return }
        loupe.update(sample: sampledPixel, format: inspector.format, kind: state.target.kind)
        loupe.follow(local, in: bounds)
    }

    func handleInspectionEvent(_ event: NSEvent) -> Bool {
        guard !frozen, highlighted,
              let action = inspector.handle(event, sample: sampledPixel) else { return false }
        let feedback: String?
        switch action {
        case .formatChanged: feedback = nil
        case .copied: feedback = "已复制 \(inspector.format.rawValue) 色值"
        case .copyFailed: feedback = "复制失败，请重试"
        }
        if let sampledPixel {
            loupe.update(sample: sampledPixel, format: inspector.format, kind: state.target.kind, feedback: feedback)
        }
        return true
    }

    private func quartzPoint(_ local: CGPoint) -> CGPoint {
        CGPoint(x: local.x + displayFrame.minX, y: local.y + displayFrame.minY)
    }

    override func mouseDown(with event: NSEvent) {
        guard !frozen else { return }
        window?.makeKey()
        let local = convert(event.locationInWindow, from: nil)
        state.mouseDown(at: quartzPoint(local))
        highlighted = true
        updateLoupe(at: local)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !frozen else { return }
        let local = convert(event.locationInWindow, from: nil)
        state.mouseDragged(to: quartzPoint(local))
        updateLoupe(at: local)
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
            // Draw inward so all four sides remain visible for full-display selections.
            let fullDisplay = state.target.kind == .display && !frozen
            let outline = NSBezierPath(rect: selection.insetBy(dx: fullDisplay ? 3 : 1, dy: fullDisplay ? 3 : 1))
            if fullDisplay {
                NSColor.black.withAlphaComponent(0.75).setStroke()
                outline.lineWidth = 6
                outline.stroke()
                NSColor.white.setStroke()
                outline.lineWidth = 4
                outline.stroke()
            }
            NSColor.controlAccentColor.setStroke()
            outline.lineWidth = fullDisplay ? 3 : 2
            outline.stroke()
        }
    }
}
