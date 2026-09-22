import AppKit

// A small native vector mark, rendered at all macOS icon sizes during packaging.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        let unit = CGFloat(size) / 1024
        context.scaleBy(x: unit, y: unit)
        let shape = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 206, yRadius: 206)
        let gradient = NSGradient(starting: NSColor(srgbRed: 0.12, green: 0.64, blue: 0.64, alpha: 1),
                                  ending: NSColor(srgbRed: 0.09, green: 0.32, blue: 0.40, alpha: 1))!
        gradient.draw(in: shape, angle: -65)
        NSColor.white.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: NSRect(x: 255, y: 232, width: 445, height: 445), xRadius: 78, yRadius: 78).fill()
        NSColor.white.withAlphaComponent(0.94).setStroke()
        let front = NSBezierPath(roundedRect: NSRect(x: 331, y: 339, width: 438, height: 438), xRadius: 74, yRadius: 74)
        front.lineWidth = 42
        front.stroke()
        NSColor.white.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: NSRect(x: 424, y: 438, width: 242, height: 38), xRadius: 19, yRadius: 19).fill()
        NSBezierPath(roundedRect: NSRect(x: 424, y: 533, width: 165, height: 38), xRadius: 19, yRadius: 19).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let path = output.appending(path: "icon_\(points)x\(points)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: path)
    }
}
