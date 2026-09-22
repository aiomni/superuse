import AppKit
import ScreenCaptureKit
import SuseCore

@MainActor
enum CaptureSelection {
    case region(CGRect, ScreenSnapshot)
    case window(SCWindow)
}

@MainActor
private final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class SelectionController {
    enum Mode { case region, window }
    private var overlays: [NSWindow] = []
    private var continuation: CheckedContinuation<CaptureSelection?, Never>?

    func select(snapshots: [ScreenSnapshot], windows: [SCWindow], mode: Mode,
                allowsWindowMode: Bool = true) async -> CaptureSelection? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            for snapshot in snapshots {
                let window = SelectionWindow(contentRect: snapshot.appKitFrame, styleMask: .borderless,
                                             backing: .buffered, defer: false)
                window.level = .screenSaver
                window.isOpaque = true
                window.hasShadow = false
                window.acceptsMouseMovedEvents = true
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                let view = SelectionView(snapshot: snapshot, windows: windows, mode: mode, allowsWindowMode: allowsWindowMode)
                view.onSelect = { [weak self] selection in self?.finish(selection) }
                view.onToggleMode = { [weak self] in
                    for overlay in self?.overlays ?? [] { (overlay.contentView as? SelectionView)?.toggleMode() }
                }
                window.contentView = view
                window.orderFrontRegardless()
                overlays.append(window)
            }
            let active = overlays.first { $0.frame.contains(NSEvent.mouseLocation) } ?? overlays.first
            active?.makeKey()
            NSApp.activate()
        }
    }

    func cancel() { finish(nil) }

    private func finish(_ result: CaptureSelection?) {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        let completion = continuation
        continuation = nil
        completion?.resume(returning: result)
    }
}

@MainActor
private final class SelectionView: NSView {
    private let snapshot: ScreenSnapshot
    private let windows: [SCWindow]
    private var mode: SelectionController.Mode
    private let allowsWindowMode: Bool
    private var anchor: CGPoint?
    private var region: CGRect?
    private var hoveredWindow: SCWindow?
    private var tracking: NSTrackingArea?
    var onSelect: ((CaptureSelection?) -> Void)?
    var onToggleMode: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    init(snapshot: ScreenSnapshot, windows: [SCWindow], mode: SelectionController.Mode, allowsWindowMode: Bool) {
        self.snapshot = snapshot
        self.windows = windows
        self.mode = mode
        self.allowsWindowMode = allowsWindowMode
        super.init(frame: CGRect(origin: .zero, size: snapshot.appKitFrame.size))
        setAccessibilityLabel("截图选区。拖动选择区域；空格切换窗口选择；Escape 取消。")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: mode == .window ? .pointingHand : .crosshair) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    func toggleMode() {
        guard allowsWindowMode else { return }
        mode = mode == .region ? .window : .region
        region = nil
        anchor = nil
        updateHoveredWindow()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onSelect?(nil) }
        else if event.keyCode == 49 { onToggleMode?() }
    }

    override func mouseMoved(with event: NSEvent) { updateHoveredWindow(); needsDisplay = true }

    private func updateHoveredWindow() {
        let point = NSEvent.mouseLocation
        let quartz = CGPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).height - point.y)
        hoveredWindow = windows.first { $0.frame.contains(quartz) }
    }

    override func mouseDown(with event: NSEvent) {
        if mode == .window {
            updateHoveredWindow()
            if let hoveredWindow { onSelect?(.window(hoveredWindow)) }
            return
        }
        anchor = convert(event.locationInWindow, from: nil)
        region = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        region = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                        width: abs(point.x - anchor.x), height: abs(point.y - anchor.y)).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .region, let region, region.width >= 4, region.height >= 4 else { return }
        let quartz = region.offsetBy(dx: snapshot.display.frame.minX, dy: snapshot.display.frame.minY)
        onSelect?(.region(quartz, snapshot))
    }

    override func draw(_ dirtyRect: NSRect) {
        let image = NSImage(cgImage: snapshot.image, size: bounds.size)
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        let selection: CGRect?
        if mode == .window {
            selection = hoveredWindow?.frame.offsetBy(dx: -snapshot.display.frame.minX, dy: -snapshot.display.frame.minY)
        } else { selection = region }
        let shade = NSBezierPath(rect: bounds)
        if let selection { shade.appendRect(selection.intersection(bounds)) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill()
        shade.fill()
        if let selection {
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(rect: selection)
            outline.lineWidth = 2
            outline.stroke()
        }
        let help = mode == .window ? "移动鼠标自动选择窗口 · 点击截图 · 空格切换区域 · Esc 取消" :
            (allowsWindowMode ? "拖动选择区域 · 空格自动选择窗口 · Esc 取消" : "拖动选择滚动内容区域，避开固定页眉和侧栏 · Esc 取消")
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white]
        let size = (help as NSString).size(withAttributes: attributes)
        let helpRect = CGRect(x: (bounds.width - size.width) / 2 - 18, y: 36, width: size.width + 36, height: 40)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: helpRect, xRadius: 20, yRadius: 20).fill()
        (help as NSString).draw(at: CGPoint(x: helpRect.minX + 18, y: helpRect.minY + 11), withAttributes: attributes)
    }
}
