import Foundation
import CoreGraphics

/// Window coordinates are AppKit points; image pixels are never resized here.
public enum PinGeometry {
    /// Initial title-bar allowance; displayed windows use their actual native content dimensions.
    public static let controlsHeight: CGFloat = 48
    public static let minimumSize = CGSize(width: 280, height: 168)

    public static func initialFrame(contentSize: CGSize, on screen: CGRect, anchor: CGPoint) -> CGRect {
        let width = min(max(minimumSize.width, contentSize.width), min(640, screen.width * 0.8))
        let scale = min(1, width / max(1, contentSize.width))
        let height = min(max(minimumSize.height, contentSize.height * scale + controlsHeight), screen.height * 0.75)
        return constrain(CGRect(x: anchor.x, y: anchor.y - height, width: width, height: height), to: screen)
    }

    public static func constrain(_ frame: CGRect, to screen: CGRect) -> CGRect {
        let size = CGSize(width: min(frame.width, screen.width), height: min(frame.height, screen.height))
        return CGRect(x: min(max(frame.minX, screen.minX), screen.maxX - size.width),
                      y: min(max(frame.minY, screen.minY), screen.maxY - size.height),
                      width: size.width, height: size.height)
    }

    /// Handles removed displays, negative origins, and windows larger than the remaining display.
    public static func recover(_ frame: CGRect, screens: [CGRect]) -> CGRect {
        guard !screens.isEmpty else { return frame }
        if screens.contains(where: { $0.contains(frame) }) { return frame }
        let screen = screens.max { lhs, rhs in
            let a = lhs.intersection(frame), b = rhs.intersection(frame)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        } ?? screens[0]
        return constrain(frame, to: screen)
    }
}

public struct PinResourceLimits: Sendable {
    public let count: Int
    public let bytes: Int
    public let imagePixels: Int

    public init(count: Int = 16, bytes: Int = 256 * 1_024 * 1_024, imagePixels: Int = 48_000_000) {
        self.count = count
        self.bytes = bytes
        self.imagePixels = imagePixels
    }

    public func accepts(bytes additional: Int, currentBytes: Int, currentCount: Int) -> Bool {
        additional > 0 && currentCount < count && currentBytes >= 0 && currentBytes <= bytes
            && additional <= bytes - currentBytes
    }

    public func acceptsImage(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && height <= imagePixels && width <= imagePixels / height
    }
}
