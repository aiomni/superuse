import CoreGraphics
import Foundation

public struct CaptureColor: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public enum CaptureColorFormat: String, CaseIterable, Sendable {
    case rgb = "RGB", hex = "HEX", hsl = "HSL"

    public var next: Self {
        switch self {
        case .rgb: .hex
        case .hex: .hsl
        case .hsl: .rgb
        }
    }

    public func string(for color: CaptureColor) -> String {
        switch self {
        case .rgb:
            return "rgb(\(color.red), \(color.green), \(color.blue))"
        case .hex:
            return String(format: "#%02X%02X%02X", Int(color.red), Int(color.green), Int(color.blue))
        case .hsl:
            let r = Double(color.red) / 255, g = Double(color.green) / 255, b = Double(color.blue) / 255
            let high = max(r, g, b), low = min(r, g, b), delta = high - low
            let lightness = (high + low) / 2
            var hue = 0.0
            if delta > 0 {
                if high == r { hue = (g - b) / delta }
                else if high == g { hue = (b - r) / delta + 2 }
                else { hue = (r - g) / delta + 4 }
                hue = (hue * 60 + 360).truncatingRemainder(dividingBy: 360)
            }
            let saturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))
            return "hsl(\(Int(hue.rounded()) % 360), \(Int((saturation * 100).rounded()))%, \(Int((lightness * 100).rounded()))%)"
        }
    }
}

public struct CapturePixel: Equatable, Sendable {
    /// Pixel coordinates relative to the captured display's top-left corner.
    public let x: Int
    public let y: Int
    public let color: CaptureColor
}

/// Samples the immutable capture in sRGB, without duplicating the full bitmap.
public final class CapturePixelSampler {
    private let image: CGImage
    private let displayFrame: CGRect
    private let context: CGContext?

    public init(image: CGImage, displayFrame: CGRect) {
        self.image = image
        self.displayFrame = displayFrame
        context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    }

    public func sample(at point: CGPoint) -> CapturePixel? {
        guard point.x.isFinite, point.y.isFinite, displayFrame.width > 0, displayFrame.height > 0,
              let context, let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let pixelX = (point.x - displayFrame.minX) * (CGFloat(image.width) / displayFrame.width)
        let pixelY = (point.y - displayFrame.minY) * (CGFloat(image.height) / displayFrame.height)
        let x = Int(min(max(pixelX, 0), CGFloat(image.width - 1)))
        let y = Int(min(max(pixelY, 0), CGFloat(image.height - 1)))
        guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        context.setBlendMode(.copy)
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let alpha = Int(bytes[3])
        func channel(_ index: Int) -> UInt8 {
            alpha == 0 ? 0 : UInt8(min(255, (Int(bytes[index]) * 255 + alpha / 2) / alpha))
        }
        return CapturePixel(x: x, y: y, color: CaptureColor(red: channel(0), green: channel(1), blue: channel(2)))
    }
}
