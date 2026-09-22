import CoreGraphics

public enum MosaicFilter {
    /// A small bitmap with one downsampled color per block. Draw it over the source
    /// bounds with interpolation disabled to produce the mosaic without caching
    /// another full-resolution screenshot for each annotation. The optional
    /// overlay draws in source-pixel coordinates with a top-left origin.
    public static func makeTiles(from image: CGImage, blockSize: Int,
                                 drawOverlay: (CGContext) -> Void = { _ in }) -> CGImage? {
        guard blockSize > 0 else { return nil }
        let width = max(1, Int(ceil(Double(image.width) / Double(blockSize))))
        let height = max(1, Int(ceil(Double(image.height) / Double(blockSize))))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / CGFloat(image.width),
                        y: -CGFloat(height) / CGFloat(image.height))
        drawOverlay(context)
        return context.makeImage()
    }
}
