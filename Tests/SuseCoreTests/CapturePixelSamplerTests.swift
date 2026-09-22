import CoreGraphics
import Foundation
import Testing
@testable import SuseCore

@Test func captureColorFormatsCoverPrimariesAndGrays() {
    let cases: [(CaptureColor, String, String)] = [
        (.init(red: 255, green: 0, blue: 0), "#FF0000", "hsl(0, 100%, 50%)"),
        (.init(red: 0, green: 255, blue: 0), "#00FF00", "hsl(120, 100%, 50%)"),
        (.init(red: 0, green: 0, blue: 255), "#0000FF", "hsl(240, 100%, 50%)"),
        (.init(red: 255, green: 255, blue: 0), "#FFFF00", "hsl(60, 100%, 50%)"),
        (.init(red: 0, green: 0, blue: 0), "#000000", "hsl(0, 0%, 0%)"),
        (.init(red: 255, green: 255, blue: 255), "#FFFFFF", "hsl(0, 0%, 100%)"),
        (.init(red: 128, green: 128, blue: 128), "#808080", "hsl(0, 0%, 50%)"),
        (.init(red: 255, green: 0, blue: 1), "#FF0001", "hsl(0, 100%, 50%)"),
    ]
    for (color, hex, hsl) in cases {
        #expect(CaptureColorFormat.rgb.string(for: color) == "rgb(\(color.red), \(color.green), \(color.blue))")
        #expect(CaptureColorFormat.hex.string(for: color) == hex)
        #expect(CaptureColorFormat.hsl.string(for: color) == hsl)
    }
    #expect(CaptureColorFormat.rgb.next == .hex)
    #expect(CaptureColorFormat.rgb.next.next == .hsl)
    #expect(CaptureColorFormat.rgb.next.next.next == .rgb)
}

@Test func captureSamplerMapsRetinaPixelsAndNegativeDisplayOrigins() throws {
    var bytes = [UInt8]()
    for y in 0..<4 {
        for x in 0..<6 { bytes += [UInt8(x * 40), UInt8(y * 60), 30, 255] }
    }
    let image = try #require(CGImage(width: 6, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 24,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                                    shouldInterpolate: false, intent: .defaultIntent))
    let frame = CGRect(x: -100, y: -20, width: 3, height: 2)
    let sampler = CapturePixelSampler(image: image, displayFrame: frame)
    for y in 0..<4 {
        for x in 0..<6 {
            let point = CGPoint(x: frame.minX + (CGFloat(x) + 0.2) / 2,
                                y: frame.minY + (CGFloat(y) + 0.2) / 2)
            let sample = try #require(sampler.sample(at: point))
            #expect(sample.x == x && sample.y == y)
            #expect(sample.color == CaptureColor(red: UInt8(x * 40), green: UInt8(y * 60), blue: 30))
        }
    }
    #expect(sampler.sample(at: CGPoint(x: -200, y: -200))?.x == 0)
    let edge = try #require(sampler.sample(at: CGPoint(x: frame.maxX, y: frame.maxY)))
    #expect(edge.x == 5 && edge.y == 3)
    #expect(sampler.sample(at: CGPoint(x: CGFloat.infinity, y: 0)) == nil)
}

@Test func captureSamplerConvertsWideGamutColorToSRGB() throws {
    let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let source = try #require(CGColor(colorSpace: space, components: [0.5, 0.6, 0.4, 1]))
    let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(source)
    context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    let image = try #require(context.makeImage())
    let sampler = CapturePixelSampler(image: image, displayFrame: CGRect(x: 0, y: 0, width: 1, height: 1))
    let sample = try #require(sampler.sample(at: .zero))
    let expected = try #require(source.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                intent: .defaultIntent, options: nil)?.components)
    for (channel, component) in zip([sample.color.red, sample.color.green, sample.color.blue], expected) {
        #expect(abs(Int(channel) - Int((component * 255).rounded())) <= 2)
    }
}

@Test func captureSamplerDoesNotRoundRetinaBoundariesIntoThePreviousPixel() throws {
    let context = try #require(CGContext(data: nil, width: 2880, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let sampler = CapturePixelSampler(image: image, displayFrame: CGRect(x: -1440, y: 0, width: 1440, height: 1))
    for x in 0..<1440 {
        #expect(sampler.sample(at: CGPoint(x: x - 1440, y: 0))?.x == x * 2)
    }
}
