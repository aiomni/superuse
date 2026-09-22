import CoreGraphics
import Foundation
import Testing
@testable import SuseCore

@Test func mosaicTilesPreserveOrientationAndCoverNondivisibleDimensions() throws {
    let image = mosaicBands()
    let tiles = try #require(MosaicFilter.makeTiles(from: image, blockSize: 4))
    #expect(tiles.width == 5 && tiles.height == 3)
    var bytes = [UInt8](repeating: 0, count: tiles.width * tiles.height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: tiles.width, height: tiles.height,
                                bitsPerComponent: 8, bytesPerRow: tiles.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(tiles, in: CGRect(x: 0, y: 0, width: tiles.width, height: tiles.height))
    }
    #expect(bytes[0] > bytes[2])
    let lastRow = (tiles.height - 1) * tiles.width * 4
    #expect(bytes[lastRow + 2] > bytes[lastRow])
    let largeBlocks = try #require(MosaicFilter.makeTiles(from: image, blockSize: 100))
    #expect(largeBlocks.width == 1 && largeBlocks.height == 1)
}

@Test func mosaicRejectsInvalidBlockSizes() {
    let image = mosaicBands()
    #expect(MosaicFilter.makeTiles(from: image, blockSize: 0) == nil)
    #expect(MosaicFilter.makeTiles(from: image, blockSize: -1) == nil)
}

private func mosaicBands() -> CGImage {
    let width = 17, height = 11
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let index = (y * width + x) * 4
            bytes[index] = y < 6 ? 240 : 10
            bytes[index + 1] = 30
            bytes[index + 2] = y < 6 ? 10 : 240
        }
    }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                   shouldInterpolate: false, intent: .defaultIntent)!
}
