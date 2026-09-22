import Foundation
import CoreGraphics

public enum ScreenGeometry {
    /// AppKit's origin is bottom-left; ScreenCaptureKit uses the main display's top-left.
    /// Keep the main display height, not the union of all displays (which breaks stacked monitors).
    public static func quartzRect(fromAppKit rect: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func pixelCrop(selection: CGRect, displayFrame: CGRect, pixelSize: CGSize) -> CGRect {
        let clipped = selection.intersection(displayFrame)
        guard !clipped.isNull, displayFrame.width > 0, displayFrame.height > 0 else { return .null }
        let scaleX = pixelSize.width / displayFrame.width
        let scaleY = pixelSize.height / displayFrame.height
        return CGRect(x: (clipped.minX - displayFrame.minX) * scaleX,
                      y: (clipped.minY - displayFrame.minY) * scaleY,
                      width: clipped.width * scaleX, height: clipped.height * scaleY).integral
            .intersection(CGRect(origin: .zero, size: pixelSize))
    }
}
