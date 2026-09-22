import AppKit

@MainActor
enum AppIcon {
    /// A compact outline of the app icon's toolbox. AppKit supplies the menu bar tint.
    static let statusBarImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let body = NSBezierPath()
            body.move(to: NSPoint(x: 3.25, y: 2.25))
            body.line(to: NSPoint(x: 14.75, y: 2.25))
            body.curve(to: NSPoint(x: 16.25, y: 3.75),
                       controlPoint1: NSPoint(x: 15.75, y: 2.25), controlPoint2: NSPoint(x: 16.25, y: 2.75))
            body.line(to: NSPoint(x: 16.25, y: 9.85))
            body.curve(to: NSPoint(x: 15.96, y: 10.75),
                       controlPoint1: NSPoint(x: 16.25, y: 10.2), controlPoint2: NSPoint(x: 16.15, y: 10.47))
            body.line(to: NSPoint(x: 14.67, y: 12.65))
            body.curve(to: NSPoint(x: 13.85, y: 13.1),
                       controlPoint1: NSPoint(x: 14.44, y: 12.98), controlPoint2: NSPoint(x: 14.2, y: 13.1))
            body.line(to: NSPoint(x: 4.15, y: 13.1))
            body.curve(to: NSPoint(x: 3.33, y: 12.65),
                       controlPoint1: NSPoint(x: 3.8, y: 13.1), controlPoint2: NSPoint(x: 3.56, y: 12.98))
            body.line(to: NSPoint(x: 2.04, y: 10.75))
            body.curve(to: NSPoint(x: 1.75, y: 9.85),
                       controlPoint1: NSPoint(x: 1.85, y: 10.47), controlPoint2: NSPoint(x: 1.75, y: 10.2))
            body.line(to: NSPoint(x: 1.75, y: 3.75))
            body.curve(to: NSPoint(x: 3.25, y: 2.25),
                       controlPoint1: NSPoint(x: 1.75, y: 2.75), controlPoint2: NSPoint(x: 2.25, y: 2.25))
            body.close()
            body.lineWidth = 1.25
            body.stroke()

            let details = NSBezierPath()
            details.move(to: NSPoint(x: 6, y: 13.1))
            details.line(to: NSPoint(x: 6, y: 15))
            details.curve(to: NSPoint(x: 7, y: 16),
                          controlPoint1: NSPoint(x: 6, y: 15.65), controlPoint2: NSPoint(x: 6.35, y: 16))
            details.line(to: NSPoint(x: 11, y: 16))
            details.curve(to: NSPoint(x: 12, y: 15),
                          controlPoint1: NSPoint(x: 11.65, y: 16), controlPoint2: NSPoint(x: 12, y: 15.65))
            details.line(to: NSPoint(x: 12, y: 13.1))
            details.move(to: NSPoint(x: 2, y: 9.5))
            details.line(to: NSPoint(x: 16, y: 9.5))
            details.lineWidth = 1.25
            details.lineCapStyle = .round
            details.stroke()

            for x: CGFloat in [4.25, 12.1] {
                NSBezierPath(roundedRect: NSRect(x: x, y: 8, width: 1.65, height: 3),
                             xRadius: 0.55, yRadius: 0.55).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = AppIdentity.name
        return image
    }()
}
