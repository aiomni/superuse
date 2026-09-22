import Foundation
import CoreGraphics

public struct CaptureWindow: Equatable, Sendable {
    public let id: UInt32
    public let frame: CGRect

    public init(id: UInt32, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

public struct CaptureTarget: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case display, window(UInt32), region }
    public let kind: Kind
    public let rect: CGRect

    public init(kind: Kind, rect: CGRect) {
        self.kind = kind
        self.rect = rect
    }
}

/// All points use Quartz coordinates. A click accepts the hovered target; a drag
/// always defines a region, even when it starts over a window or a full-screen app.
public struct CaptureSelectionState {
    public let displayFrame: CGRect
    private let windows: [CaptureWindow]
    public private(set) var target: CaptureTarget
    public private(set) var isConfirmed = false
    private var anchor: CGPoint?
    private var isDragging = false

    public init(displayFrame: CGRect, windows: [CaptureWindow]) {
        self.displayFrame = displayFrame
        self.windows = windows
        target = CaptureTarget(kind: .display, rect: displayFrame)
    }

    public mutating func hover(at point: CGPoint) {
        guard !isConfirmed, anchor == nil else { return }
        target = automaticTarget(at: point)
    }

    public mutating func mouseDown(at point: CGPoint) {
        guard !isConfirmed, displayFrame.contains(point) else { return }
        target = automaticTarget(at: point)
        anchor = point
        isDragging = false
    }

    public mutating func mouseDragged(to point: CGPoint) {
        guard !isConfirmed, let anchor else { return }
        // Ignore the small movement that often accompanies a trackpad click.
        if hypot(point.x - anchor.x, point.y - anchor.y) >= 4 { isDragging = true }
        guard isDragging else { return }
        let rect = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                          width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
            .intersection(displayFrame)
        target = CaptureTarget(kind: .region, rect: rect)
    }

    @discardableResult
    public mutating func mouseUp(at point: CGPoint) -> CaptureTarget? {
        guard anchor != nil, !isConfirmed else { return nil }
        mouseDragged(to: point)
        anchor = nil
        guard !isDragging || (target.rect.width >= 4 && target.rect.height >= 4) else {
            target = automaticTarget(at: point)
            return nil
        }
        isConfirmed = true
        return target
    }

    private func automaticTarget(at point: CGPoint) -> CaptureTarget {
        guard let window = windows.first(where: { $0.frame.contains(point) }) else {
            return CaptureTarget(kind: .display, rect: displayFrame)
        }
        let clipped = window.frame.intersection(displayFrame)
        // Full-screen windows can differ by a point at the edge due to rounding.
        let coversDisplay = window.frame.insetBy(dx: -1, dy: -1).contains(displayFrame)
        return CaptureTarget(kind: coversDisplay ? .display : .window(window.id),
                             rect: coversDisplay ? displayFrame : clipped)
    }
}
