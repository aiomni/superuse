import CoreGraphics

/// Adjusts a selected region in the coordinate space of its containing display.
public enum CaptureRegionHandle: Int, CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    public func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        }
    }
}

public struct CaptureRegionAdjustment: Sendable {
    public let original: CGRect
    public let displayFrame: CGRect
    public let start: CGPoint
    public let handle: CaptureRegionHandle?

    public init(rect: CGRect, displayFrame: CGRect, start: CGPoint, handle: CaptureRegionHandle?) {
        self.original = rect
        self.displayFrame = displayFrame
        self.start = start
        self.handle = handle
    }

    public func rect(at point: CGPoint) -> CGRect {
        let dx = point.x - start.x, dy = point.y - start.y
        guard let handle else {
            let x = min(max(original.minX + dx, displayFrame.minX), displayFrame.maxX - original.width)
            let y = min(max(original.minY + dy, displayFrame.minY), displayFrame.maxY - original.height)
            return CGRect(x: x, y: y, width: original.width, height: original.height)
        }
        let minWidth = min(4, original.width), minHeight = min(4, original.height)
        var left = original.minX, right = original.maxX, top = original.minY, bottom = original.maxY
        if [.topLeft, .left, .bottomLeft].contains(handle) {
            left = min(max(original.minX + dx, displayFrame.minX), right - minWidth)
        }
        if [.topRight, .right, .bottomRight].contains(handle) {
            right = max(min(original.maxX + dx, displayFrame.maxX), left + minWidth)
        }
        if [.topLeft, .top, .topRight].contains(handle) {
            top = min(max(original.minY + dy, displayFrame.minY), bottom - minHeight)
        }
        if [.bottomLeft, .bottom, .bottomRight].contains(handle) {
            bottom = max(min(original.maxY + dy, displayFrame.maxY), top + minHeight)
        }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
