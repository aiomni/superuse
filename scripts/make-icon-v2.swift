import AppKit

// superuse's macOS utility case: anodized teal, satin metal, and a rubber grip.
// Usage: swift scripts/make-icon-v2.swift Resources/AppIcon-v2/superuse.iconset
// Coordinates are in a 1024-point, bottom-left-origin design space.
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon-v2/superuse.iconset",
                 isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func saved(_ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

// Continuous corners transition gradually from the straight edges.
func tile(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height, r = radius
    p.move(to: NSPoint(x: x + r, y: y))
    p.line(to: NSPoint(x: x + w - r, y: y))
    p.curve(to: NSPoint(x: x + w, y: y + r),
            controlPoint1: NSPoint(x: x + w - r * 0.28, y: y),
            controlPoint2: NSPoint(x: x + w, y: y + r * 0.28))
    p.line(to: NSPoint(x: x + w, y: y + h - r))
    p.curve(to: NSPoint(x: x + w - r, y: y + h),
            controlPoint1: NSPoint(x: x + w, y: y + h - r * 0.28),
            controlPoint2: NSPoint(x: x + w - r * 0.28, y: y + h))
    p.line(to: NSPoint(x: x + r, y: y + h))
    p.curve(to: NSPoint(x: x, y: y + h - r),
            controlPoint1: NSPoint(x: x + r * 0.28, y: y + h),
            controlPoint2: NSPoint(x: x, y: y + h - r * 0.28))
    p.line(to: NSPoint(x: x, y: y + r))
    p.curve(to: NSPoint(x: x + r, y: y),
            controlPoint1: NSPoint(x: x, y: y + r * 0.28),
            controlPoint2: NSPoint(x: x + r * 0.28, y: y))
    p.close()
    return p
}

func linear(_ path: NSBezierPath, _ stops: [(CGFloat, NSColor)], angle: CGFloat = 90) {
    let locations = stops.map(\.0)
    let gradient = NSGradient(colors: stops.map(\.1), atLocations: locations, colorSpace: .sRGB)!
    gradient.draw(in: path, angle: angle)
}

func glow(_ path: NSBezierPath, center: CGPoint, radius: CGFloat, tint: NSColor) {
    saved {
        path.addClip()
        let context = NSGraphicsContext.current!.cgContext
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [tint.cgColor, tint.withAlphaComponent(0).cgColor] as CFArray,
                                  locations: [0, 1])!
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: radius, options: [])
    }
}

func shadow(_ path: NSBezierPath, offset: CGSize, blur: CGFloat, opacity: CGFloat, fill: NSColor) {
    saved {
        let context = NSGraphicsContext.current!.cgContext
        context.setShadow(offset: offset, blur: blur, color: color(0x003C4A, opacity).cgColor)
        fill.setFill()
        path.fill()
    }
}

func edge(_ path: NSBezierPath, width: CGFloat, color: NSColor) {
    path.lineWidth = width
    color.setStroke()
    path.stroke()
}

func insetShade(_ path: NSBezierPath, offset: CGSize, blur: CGFloat, tint: NSColor) {
    saved {
        path.addClip()
        let inverse = NSBezierPath(rect: CGRect(x: -200, y: -200, width: 1424, height: 1424))
        inverse.append(path)
        inverse.windingRule = .evenOdd
        let context = NSGraphicsContext.current!.cgContext
        context.setShadow(offset: offset, blur: blur, color: tint.cgColor)
        NSColor.black.setFill()
        inverse.fill()
    }
}

func utilityCase() {
    // The complete object is seen slightly from above, with one consistent light source.
    let body = tile(CGRect(x: 236, y: 274, width: 552, height: 330), radius: 57)
    shadow(body, offset: CGSize(width: 0, height: -20), blur: 32, opacity: 0.24, fill: color(0x168895))

    for x: CGFloat in [299, 647] {
        let foot = NSBezierPath(roundedRect: CGRect(x: x, y: 262, width: 78, height: 29), xRadius: 10, yRadius: 10)
        linear(foot, [(0, color(0x355B63)), (1, color(0x477D82))])
    }
    linear(body, [(0, color(0x087F8C)), (0.45, color(0x1FA5A8)), (1, color(0x62CEC1))], angle: 100)
    glow(body, center: CGPoint(x: 276, y: 581), radius: 610, tint: color(0xBAFCEC, 0.23))
    glow(body, center: CGPoint(x: 781, y: 271), radius: 470, tint: color(0x00567B, 0.34))
    insetShade(body, offset: CGSize(width: 0, height: -3), blur: 4, tint: color(0xCBFFF0, 0.40))
    insetShade(body, offset: CGSize(width: 0, height: 5), blur: 7, tint: color(0x004B64, 0.29))

    // Four pressed channels give the case a physical, sturdy front without a logo.
    for x: CGFloat in [308, 431, 554, 677] {
        let channel = NSBezierPath(roundedRect: CGRect(x: x, y: 323, width: 12, height: 117), xRadius: 6, yRadius: 6)
        color(0x06657B, 0.17).setFill()
        channel.fill()
        let highlight = NSBezierPath(roundedRect: CGRect(x: x + 9, y: 326, width: 3, height: 109), xRadius: 1.5, yRadius: 1.5)
        color(0xCCFFF2, 0.23).setFill()
        highlight.fill()
    }

    // Raised lid: the trapezoid is the top plane, the narrow curved band is its lip.
    let top = NSBezierPath()
    top.move(to: CGPoint(x: 230, y: 586))
    top.curve(to: CGPoint(x: 248, y: 626), controlPoint1: CGPoint(x: 229, y: 603), controlPoint2: CGPoint(x: 239, y: 614))
    top.line(to: CGPoint(x: 284, y: 674))
    top.curve(to: CGPoint(x: 322, y: 691), controlPoint1: CGPoint(x: 294, y: 687), controlPoint2: CGPoint(x: 304, y: 691))
    top.line(to: CGPoint(x: 702, y: 691))
    top.curve(to: CGPoint(x: 740, y: 674), controlPoint1: CGPoint(x: 720, y: 691), controlPoint2: CGPoint(x: 730, y: 687))
    top.line(to: CGPoint(x: 776, y: 626))
    top.curve(to: CGPoint(x: 794, y: 586), controlPoint1: CGPoint(x: 785, y: 614), controlPoint2: CGPoint(x: 795, y: 603))
    top.close()
    shadow(top, offset: CGSize(width: 0, height: -8), blur: 12, opacity: 0.16, fill: color(0x62D2C3))
    linear(top, [(0, color(0x61C9BE)), (0.62, color(0x9BE5D6)), (1, color(0xC8F5E4))], angle: 90)
    insetShade(top, offset: CGSize(width: 0, height: -3), blur: 3, tint: color(0xF0FFF5, 0.63))

    let seam = NSBezierPath(roundedRect: CGRect(x: 236, y: 544, width: 552, height: 13), xRadius: 5, yRadius: 5)
    shadow(seam, offset: CGSize(width: 0, height: -3), blur: 6, opacity: 0.19, fill: color(0x106D7B))
    let lip = tile(CGRect(x: 228, y: 553, width: 568, height: 54), radius: 19)
    linear(lip, [(0, color(0x2B9F9F)), (0.55, color(0x4ABDB2)), (1, color(0x81DBCC))])
    insetShade(lip, offset: CGSize(width: 0, height: -2), blur: 2, tint: color(0xDBFFF0, 0.72))
    insetShade(lip, offset: CGSize(width: 0, height: 3), blur: 3, tint: color(0x026277, 0.32))

    // Handle mounts sit on the lid; a satin metal hoop carries a dark rubber grip.
    for x: CGFloat in [382, 577] {
        let mount = NSBezierPath(roundedRect: CGRect(x: x, y: 641, width: 66, height: 31), xRadius: 10, yRadius: 10)
        shadow(mount, offset: CGSize(width: 0, height: -4), blur: 6, opacity: 0.20, fill: color(0x4A9296))
        linear(mount, [(0, color(0x5B949C)), (0.5, color(0xBBD8D7)), (1, color(0xEDF8EE))])
    }
    let handle = NSBezierPath()
    handle.move(to: CGPoint(x: 393, y: 661))
    handle.line(to: CGPoint(x: 393, y: 752))
    handle.curve(to: CGPoint(x: 450, y: 809), controlPoint1: CGPoint(x: 393, y: 786), controlPoint2: CGPoint(x: 416, y: 809))
    handle.line(to: CGPoint(x: 574, y: 809))
    handle.curve(to: CGPoint(x: 631, y: 752), controlPoint1: CGPoint(x: 608, y: 809), controlPoint2: CGPoint(x: 631, y: 786))
    handle.line(to: CGPoint(x: 631, y: 661))
    handle.line(to: CGPoint(x: 587, y: 661))
    handle.line(to: CGPoint(x: 587, y: 746))
    handle.curve(to: CGPoint(x: 566, y: 767), controlPoint1: CGPoint(x: 587, y: 759), controlPoint2: CGPoint(x: 579, y: 767))
    handle.line(to: CGPoint(x: 458, y: 767))
    handle.curve(to: CGPoint(x: 437, y: 746), controlPoint1: CGPoint(x: 445, y: 767), controlPoint2: CGPoint(x: 437, y: 759))
    handle.line(to: CGPoint(x: 437, y: 661))
    handle.close()
    shadow(handle, offset: CGSize(width: 0, height: -7), blur: 8, opacity: 0.19, fill: color(0x7C989F))
    linear(handle, [(0, color(0x799EA5)), (0.18, color(0xE4EEEB)), (0.47, color(0xA7C5C7)),
                    (0.8, color(0xD8E7E5)), (1, color(0xF6FAF4))], angle: 8)
    insetShade(handle, offset: CGSize(width: 0, height: -2), blur: 2, tint: color(0xFFFFFF, 0.90))
    insetShade(handle, offset: CGSize(width: 0, height: 2), blur: 3, tint: color(0x365F6B, 0.32))

    let grip = tile(CGRect(x: 433, y: 764, width: 159, height: 48), radius: 16)
    linear(grip, [(0, color(0x294F5A)), (0.56, color(0x426C72)), (1, color(0x5D8588))])
    insetShade(grip, offset: CGSize(width: 0, height: -2), blur: 2, tint: color(0xC7E6DE, 0.44))

    // Two small machined latches identify a tool case rather than a document or bag.
    for x: CGFloat in [343, 629] {
        let latch = tile(CGRect(x: x, y: 502, width: 52, height: 109), radius: 12)
        shadow(latch, offset: CGSize(width: 1, height: -5), blur: 7, opacity: 0.25, fill: color(0x779C9C))
        linear(latch, [(0, color(0xB0CDCB)), (0.18, color(0xF0F6EB)), (0.46, color(0xC5DBD8)),
                       (0.69, color(0xF7FCF1)), (1, color(0xFEFFF7))], angle: 7)
        insetShade(latch, offset: CGSize(width: 0, height: -2), blur: 2, tint: color(0xFFFFFF, 0.80))
        insetShade(latch, offset: CGSize(width: 0, height: 2), blur: 2, tint: color(0x3B727C, 0.38))
        let joint = NSBezierPath(roundedRect: CGRect(x: x + 9, y: 554, width: 34, height: 5), xRadius: 2.5, yRadius: 2.5)
        color(0x436F78, 0.63).setFill()
        joint.fill()
        let catchPlate = NSBezierPath(roundedRect: CGRect(x: x + 13, y: 516, width: 26, height: 28), xRadius: 5, yRadius: 5)
        linear(catchPlate, [(0, color(0xBCD4D1)), (1, color(0xE9F3E9))])
    }
}

func drawIcon(size: Int) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    saved {
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.clear(CGRect(x: 0, y: 0, width: size, height: size))
        context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
        context.setAllowsAntialiasing(true)

        let baseRect = CGRect(x: 92, y: 92, width: 840, height: 840)
        let base = tile(baseRect, radius: 198)
        saved {
            context.setShadow(offset: CGSize(width: 0, height: -12), blur: 22,
                              color: color(0x243C46, 0.22).cgColor)
            color(0xE6ECEF).setFill()
            base.fill()
        }
        linear(base, [(0, color(0xE4EDEF)), (0.48, color(0xF3F7F7)), (1, color(0xFFFFFF))], angle: 100)
        glow(base, center: CGPoint(x: 288, y: 890), radius: 850, tint: color(0xFFFFFF, 0.72))
        glow(base, center: CGPoint(x: 872, y: 135), radius: 620, tint: color(0xC8E0E4, 0.20))

        // A narrow edge catches the light without adding a second enclosing frame.
        saved {
            base.addClip()
            let bevel = tile(baseRect.insetBy(dx: 2.5, dy: 2.5), radius: 196)
            edge(bevel, width: 5, color: color(0xFFFFFF, 0.70))
            let topLight = NSBezierPath()
            topLight.move(to: CGPoint(x: 289, y: 925))
            topLight.curve(to: CGPoint(x: 737, y: 925),
                           controlPoint1: CGPoint(x: 406, y: 930),
                           controlPoint2: CGPoint(x: 620, y: 930))
            topLight.lineCapStyle = .round
            edge(topLight, width: 3, color: color(0xFFFFFF, 0.80))
        }

        utilityCase()
    }
    return bitmap.converting(to: .sRGB, renderingIntent: .default) ?? bitmap
}

// Resize the finished master so Quartz's device-space shadow blur scales with
// the artwork instead of being clipped against the small bitmap boundaries.
let master = drawIcon(size: 1024)

func resizedMaster(to size: Int) -> NSBitmapImageRep {
    if size == 1024 { return master }
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    saved {
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.interpolationQuality = .high
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        context.clear(rect)
        context.draw(master.cgImage!, in: rect)
    }
    return bitmap.converting(to: .sRGB, renderingIntent: .default) ?? bitmap
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let bitmap = resizedMaster(to: points * scale)
        let suffix = scale == 2 ? "@2x" : ""
        let path = output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: path)
    }
}

print(output.path)
