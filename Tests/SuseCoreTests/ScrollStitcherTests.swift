import CoreGraphics
import Foundation
import Testing
@testable import SuseCore

private func fixture(width: Int = 128, height: Int = 900, seed: UInt32 = 42, repeating: Bool = false) -> CGImage {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            var hash = UInt32(repeating ? y % 24 : y) &* 374_761_393 &+ UInt32(x) &* 668_265_263 &+ seed
            hash = (hash ^ (hash >> 13)) &* 1_274_126_177
            let value = UInt8((hash ^ (hash >> 16)) & 255)
            for component in 0..<3 { bytes[(y * width + x) * 4 + component] = value }
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

private func crop(_ image: CGImage, y: Int, height: Int = 320) -> CGImage {
    image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: height))!
}

private func rgba(_ image: CGImage) -> Data {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return Data(bytes)
}

@Test func stitchesExactSeamsAndPreservesPixels() async throws {
    let source = fixture()
    let stitcher = ScrollStitcher()
    let first = await stitcher.append(crop(source, y: 0))
    let second = await stitcher.append(crop(source, y: 140))
    let third = await stitcher.append(crop(source, y: 300))
    #expect(first == .appended(height: 320, frames: 1))
    #expect(second == .appended(height: 460, frames: 2))
    #expect(third == .appended(height: 620, frames: 3))
    let result = try #require(await stitcher.makeImage())
    #expect(result.height == 620)
    #expect(rgba(result) == rgba(crop(source, y: 0, height: 620)))
}

@Test func ignoresStationaryFramesAndRequiresStability() async {
    let source = fixture()
    let stitcher = ScrollStitcher()
    _ = await stitcher.ingest(crop(source, y: 0))
    let stationary = await stitcher.ingest(crop(source, y: 0))
    let moving = await stitcher.ingest(crop(source, y: 80))
    let stable = await stitcher.ingest(crop(source, y: 80))
    #expect(stationary == .unchanged)
    #expect(moving == .unchanged)
    #expect(stable == .appended(height: 400, frames: 2))
}

@Test func rejectsUnrelatedOrAmbiguousContentWithoutCorruptingResult() async throws {
    let stitcher = ScrollStitcher()
    let original = crop(fixture(), y: 0)
    _ = await stitcher.append(original)
    let unrelated = await stitcher.append(crop(fixture(seed: 998), y: 200))
    guard case .rejected = unrelated else { Issue.record("Unrelated frames must be rejected"); return }
    let result = try #require(await stitcher.makeImage())
    #expect(rgba(result) == rgba(original))

    let repeating = fixture(repeating: true)
    let repeated = ScrollStitcher()
    _ = await repeated.append(crop(repeating, y: 0))
    let ambiguous = await repeated.append(crop(repeating, y: 35))
    guard case .rejected = ambiguous else { Issue.record("Repeating seams must be rejected"); return }
}

@Test func limitsMemoryAndRejectsChangedDimensions() async {
    let source = fixture()
    let stitcher = ScrollStitcher(pixelLimit: 128 * 350)
    _ = await stitcher.append(crop(source, y: 0))
    let limited = await stitcher.append(crop(source, y: 80))
    #expect(limited == .limitReached)
    let resized = await stitcher.append(crop(source, y: 80, height: 300))
    guard case .rejected = resized else { Issue.record("Changed dimensions must be rejected"); return }
}
