import AppKit
import SuseCore

/// A mouse-transparent native HUD; the magnified image remains an opaque canvas.
@MainActor
final class CaptureLoupeView: NSView {
    private let magnifier: CaptureMagnifierView
    private let coordinates = NSTextField(labelWithString: "")
    private let colorValue = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "⇧ 切换格式 · ⌘C 复制")
    private let swatch = NSBox()
    private var glass: NSGlassEffectView?

    init(image: CGImage) {
        magnifier = CaptureMagnifierView(image: image)
        super.init(frame: .zero)
        setAccessibilityIdentifier("capture-loupe")
        coordinates.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        colorValue.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        for label in [coordinates, colorValue, shortcut] {
            label.textColor = .labelColor
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        shortcut.font = .systemFont(ofSize: 10)
        shortcut.textColor = .secondaryLabelColor
        swatch.boxType = .custom
        swatch.titlePosition = .noTitle
        swatch.cornerRadius = 3
        swatch.borderWidth = 1
        swatch.borderColor = .separatorColor
        swatch.widthAnchor.constraint(equalToConstant: 12).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 12).isActive = true
        let valueRow = UI.stack([swatch, colorValue], axis: .horizontal, spacing: 6)
        valueRow.alignment = .centerY
        let content = UI.stack([magnifier, coordinates, valueRow, shortcut], spacing: 6)
        content.alignment = .centerX
        content.widthAnchor.constraint(equalToConstant: 168).isActive = true
        let glass = UI.glassBar(content, radius: 14, inset: 10)
        self.glass = glass
        glass.tintColor = .windowBackgroundColor
        addSubview(glass)
        UI.pin(glass, to: self, inset: 0)
        updateAppearance()
        frame.size = fittingSize
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAppearance() }

    private func updateAppearance() {
        guard let glass else { return }
        let contrast = effectiveAppearance.bestMatch(from: [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua, .aqua, .darkAqua])
        let highContrast = contrast == .accessibilityHighContrastAqua || contrast == .accessibilityHighContrastDarkAqua
        glass.appearance = NSAppearance(named: highContrast ? .accessibilityHighContrastDarkAqua : .darkAqua)
    }

    func update(sample: CapturePixel, format: CaptureColorFormat, kind: CaptureTarget.Kind, feedback: String? = nil) {
        magnifier.update(sample)
        coordinates.stringValue = "X: \(sample.x)   Y: \(sample.y)"
        colorValue.stringValue = format.string(for: sample.color)
        swatch.fillColor = NSColor(srgbRed: CGFloat(sample.color.red) / 255,
                                  green: CGFloat(sample.color.green) / 255,
                                  blue: CGFloat(sample.color.blue) / 255, alpha: 1)
        let selectionDescription: String
        switch kind {
        case .display: selectionDescription = "全屏，单击确认"
        case .window: selectionDescription = "窗口，单击确认"
        case .region: selectionDescription = "区域，松开确认"
        }
        shortcut.stringValue = feedback ?? "⇧ 切换格式 · ⌘C 复制"
        setAccessibilityLabel("\(selectionDescription)，\(coordinates.stringValue)，\(format.rawValue) \(colorValue.stringValue)。Shift 切换格式，Command C 复制色值，Escape 取消。")
    }

    func follow(_ cursor: CGPoint, in bounds: CGRect) {
        frame = Self.placement(cursor: cursor, size: frame.size, bounds: bounds)
    }

    static func placement(cursor: CGPoint, size: CGSize, bounds: CGRect) -> CGRect {
        let margin: CGFloat = 8, gap: CGFloat = 22
        var x = cursor.x + gap, y = cursor.y + gap
        if x + size.width > bounds.maxX - margin { x = cursor.x - gap - size.width }
        if y + size.height > bounds.maxY - margin { y = cursor.y - gap - size.height }
        x = max(bounds.minX + margin, min(x, bounds.maxX - size.width - margin))
        y = max(bounds.minY + margin, min(y, bounds.maxY - size.height - margin))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

@MainActor
private final class CaptureMagnifierView: NSView {
    private let image: CGImage
    private var sample: CapturePixel?
    private var crop: NSImage?
    private var destination = CGRect.zero
    private let cellSize: CGFloat = 8
    private let pixelCount = 17
    override var isFlipped: Bool { true }

    init(image: CGImage) {
        self.image = image
        super.init(frame: CGRect(x: 0, y: 0, width: 136, height: 136))
        widthAnchor.constraint(equalToConstant: 136).isActive = true
        heightAnchor.constraint(equalToConstant: 136).isActive = true
        setAccessibilityIdentifier("capture-magnifier")
        setAccessibilityLabel("鼠标位置的像素放大镜，中心方格为取色像素")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func update(_ next: CapturePixel) {
        guard sample?.x != next.x || sample?.y != next.y else { return }
        sample = next
        let source = CGRect(x: next.x - pixelCount / 2, y: next.y - pixelCount / 2, width: pixelCount, height: pixelCount)
        let clipped = source.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        crop = image.cropping(to: clipped).map { NSImage(cgImage: $0, size: clipped.size) }
        destination = CGRect(x: (clipped.minX - source.minX) * cellSize, y: (clipped.minY - source.minY) * cellSize,
                             width: clipped.width * cellSize, height: clipped.height * cellSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor.black.setFill()
        bounds.fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        crop?.draw(in: destination, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        let center = CGRect(x: CGFloat(pixelCount / 2) * cellSize, y: CGFloat(pixelCount / 2) * cellSize,
                            width: cellSize, height: cellSize)
        NSColor.black.setStroke()
        let marker = NSBezierPath(rect: center.insetBy(dx: -1, dy: -1))
        marker.lineWidth = 3
        marker.stroke()
        NSColor.white.setStroke()
        marker.lineWidth = 1
        marker.stroke()
        NSColor.white.withAlphaComponent(0.4).setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}
