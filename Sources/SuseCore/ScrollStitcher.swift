import CoreGraphics
import Foundation

public enum StitchResult: Equatable, Sendable {
    case appended(height: Int, frames: Int)
    case unchanged
    case rejected(String)
    case limitReached
}

/// Runs matching and image composition off the main actor. Only newly exposed strips are retained.
public actor ScrollStitcher {
    private var strips: [CGImage] = []
    private var previous: GrayFrame?
    private var candidate: GrayFrame?
    private var width = 0
    private var totalHeight = 0
    private let pixelLimit: Int
    private let heightLimit: Int

    public init(pixelLimit: Int = 48_000_000, heightLimit: Int = 30_000) {
        self.pixelLimit = pixelLimit
        self.heightLimit = heightLimit
    }

    /// Two similar samples are required, so animation frames do not become stitch anchors.
    public func ingest(_ image: CGImage) -> StitchResult {
        guard let frame = GrayFrame(image: image) else { return .rejected("无法读取画面像素。") }
        defer { candidate = frame }
        if previous == nil { return append(image, frame: frame) }
        guard let candidate, frame.isSimilar(to: candidate) else { return .unchanged }
        return append(image, frame: frame)
    }

    public func append(_ image: CGImage) -> StitchResult {
        guard let frame = GrayFrame(image: image) else { return .rejected("无法读取画面像素。") }
        return append(image, frame: frame)
    }

    private func append(_ image: CGImage, frame: GrayFrame) -> StitchResult {
        guard let previous else {
            guard image.width > 0, image.height > 0,
                  image.height <= heightLimit, image.width <= pixelLimit / image.height else { return .limitReached }
            strips = [image]
            width = image.width
            totalHeight = image.height
            self.previous = frame
            return .appended(height: totalHeight, frames: 1)
        }
        guard image.width == width, frame.height == previous.height else {
            return .rejected("选区尺寸改变，请重新开始。")
        }
        if frame.isSimilar(to: previous) { return .unchanged }
        guard let shift = previous.verticalShift(to: frame) else {
            return .rejected("未找到可靠重叠。请向上回退一些，再缓慢向下滚动；保留至少四分之一重叠。")
        }
        guard totalHeight + shift <= heightLimit, width <= pixelLimit / (totalHeight + shift) else { return .limitReached }
        guard let strip = image.cropping(to: CGRect(x: 0, y: image.height - shift, width: width, height: shift)) else {
            return .rejected("无法裁剪新内容。")
        }
        strips.append(strip)
        totalHeight += shift
        self.previous = frame
        return .appended(height: totalHeight, frames: strips.count)
    }

    public func makeImage() -> CGImage? {
        guard width > 0, totalHeight > 0,
              let context = CGContext(data: nil, width: width, height: totalHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var offset = 0
        for strip in strips {
            context.draw(strip, in: CGRect(x: 0, y: totalHeight - offset - strip.height, width: width, height: strip.height))
            offset += strip.height
        }
        return context.makeImage()
    }
}

/// Horizontal sampling keeps matching cheap while retaining every vertical pixel for exact seams.
private struct GrayFrame: Sendable {
    let pixels: [UInt8]
    let height: Int
    private static let width = 64

    init?(image: CGImage) {
        let height = image.height
        self.height = height
        guard height > 0, height <= 30_000 else { return nil }
        var data = [UInt8](repeating: 0, count: Self.width * height)
        let rendered = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: Self.width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: Self.width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: Self.width, height: height))
            return true
        }
        guard rendered else { return nil }
        pixels = data
    }

    func isSimilar(to other: GrayFrame) -> Bool {
        guard height == other.height else { return false }
        // A dense comparison prevents narrow, partially scrolled content from looking unchanged.
        var error = 0
        var count = 0
        for row in stride(from: 0, to: height, by: max(1, height / 200)) {
            for column in 4..<(Self.width - 4) {
                let index = row * Self.width + column
                error += abs(Int(pixels[index]) - Int(other.pixels[index]))
                count += 1
            }
        }
        return count > 0 && Double(error) / Double(count) < 0.8
    }

    func verticalShift(to next: GrayFrame) -> Int? {
        let minimumOverlap = max(32, height / 4)
        guard height > minimumOverlap + 2 else { return nil }
        var candidates: [(shift: Int, score: Double)] = []
        for shift in 2...(height - minimumOverlap) {
            if let score = score(next, shift: shift), score < 7 { candidates.append((shift, score)) }
        }
        guard let best = candidates.min(by: { $0.score < $1.score }), best.score < 5 else { return nil }
        // Repeating patterns can produce multiple equally plausible seams. Reject instead of guessing.
        let ambiguityDistance = max(4, height / 40)
        let ambiguous = candidates.contains {
            abs($0.shift - best.shift) > ambiguityDistance && $0.score < best.score + 0.6
        }
        return ambiguous ? nil : best.shift
    }

    private func score(_ next: GrayFrame, shift: Int) -> Double? {
        let overlap = height - shift
        var rowScores: [Double] = []
        for row in stride(from: 0, to: overlap, by: max(1, overlap / 72)) {
            let lhs = (row + shift) * Self.width
            let rhs = row * Self.width
            var low = 255
            var high = 0
            var difference = 0
            for column in 4..<(Self.width - 4) {
                let a = Int(pixels[lhs + column])
                let b = Int(next.pixels[rhs + column])
                low = min(low, a, b)
                high = max(high, a, b)
                difference += abs(a - b)
            }
            // Flat white margins are not evidence of an overlap.
            if high - low > 20 { rowScores.append(Double(difference) / Double(Self.width - 8)) }
        }
        guard rowScores.count >= 6 else { return nil }
        rowScores.sort()
        // Tolerate a small cursor, caret or sticky element; most content must still agree.
        let reliable = rowScores.prefix(max(6, rowScores.count * 9 / 10))
        return reliable.reduce(0, +) / Double(reliable.count)
    }
}
