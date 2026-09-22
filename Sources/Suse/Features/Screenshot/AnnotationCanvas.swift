import AppKit
import SuseCore

enum AnnotationTool: Int, CaseIterable {
    case pen, arrow, rectangle, ellipse, text, redact, mosaic
    var title: String { ["画笔", "箭头", "矩形", "椭圆", "文字", "遮挡", "打码"][rawValue] }
    var symbol: String { ["pencil.tip", "arrow.up.right", "rectangle", "oval", "textformat", "rectangle.fill", "checkerboard.rectangle"][rawValue] }
    var tooltip: String {
        switch self {
        case .redact: "遮挡：拖动框选，用不透明黑色覆盖"
        case .mosaic: "打码：拖动框选马赛克区域，细／中／粗调整颗粒大小"
        default: title
        }
    }
}

private struct Annotation {
    let tool: AnnotationTool
    var points: [CGPoint]
    let color: NSColor
    let width: CGFloat
    var text = ""
    var mosaicTiles: CGImage?
}

@MainActor
final class AnnotationCanvas: NSView {
    let image: CGImage
    var tool: AnnotationTool = .arrow
    var ink = NSColor.systemRed
    var lineWidth: CGFloat = 5
    var requestText: ((CGPoint) -> Void)?
    var onChange: (() -> Void)?
    private var annotations: [Annotation] = []
    private var draft: Annotation?
    private let editHistory = UndoManager()
    override var undoManager: UndoManager? { editHistory }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var annotationCount: Int { annotations.count }

    init(image: CGImage, displayWidth: CGFloat) {
        self.image = image
        super.init(frame: CGRect(x: 0, y: 0, width: displayWidth,
                                height: displayWidth * CGFloat(image.height) / CGFloat(image.width)))
        setAccessibilityLabel("截图标注画布")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: tool == .text ? .iBeam : .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        let scale = bounds.width / CGFloat(image.width)
        context.scaleBy(x: scale, y: scale)
        render(in: context, includingDraft: true)
        context.restoreGState()
    }

    func renderedImage() throws -> CGImage {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AppError("图片过大，无法创建导出画布。")
        }
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        render(in: context, includingDraft: false)
        NSGraphicsContext.restoreGraphicsState()
        guard let result = context.makeImage() else { throw AppError("无法生成图片。") }
        return result
    }

    private func render(in context: CGContext, includingDraft: Bool) {
        drawBitmap(image, in: context)
        for annotation in annotations + (includingDraft ? draft.map { [$0] } ?? [] : []) {
            draw(annotation, in: context)
        }
    }

    private func drawBitmap(_ bitmap: CGImage, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(bitmap, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.restoreGState()
    }

    private func draw(_ annotation: Annotation, in context: CGContext) {
        guard let first = annotation.points.first, let last = annotation.points.last else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(annotation.color.cgColor)
        context.setFillColor(annotation.color.cgColor)
        context.setLineWidth(annotation.width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                          width: abs(last.x - first.x), height: abs(last.y - first.y))
        switch annotation.tool {
        case .pen:
            if annotation.points.count == 1 {
                context.fillEllipse(in: CGRect(x: first.x - annotation.width / 2, y: first.y - annotation.width / 2,
                                              width: annotation.width, height: annotation.width))
            } else { context.addLines(between: annotation.points); context.strokePath() }
        case .arrow:
            context.move(to: first)
            context.addLine(to: last)
            let angle = atan2(last.y - first.y, last.x - first.x)
            let length = min(annotation.width * 4, hypot(last.x - first.x, last.y - first.y) / 2)
            for delta in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                context.move(to: last)
                context.addLine(to: CGPoint(x: last.x - length * cos(angle + delta), y: last.y - length * sin(angle + delta)))
            }
            context.strokePath()
        case .rectangle: context.stroke(rect)
        case .ellipse: context.strokeEllipse(in: rect)
        case .redact:
            context.setFillColor(NSColor.black.cgColor)
            context.fill(rect.integral)
        case .mosaic:
            context.clip(to: rect.integral)
            // Keep the covered area opaque even if the source contains transparency
            // or the downsampled bitmap cannot be allocated.
            context.setFillColor(NSColor.black.cgColor)
            context.fill(rect.integral)
            if let tiles = annotation.mosaicTiles {
                context.interpolationQuality = .none
                drawBitmap(tiles, in: context)
            }
        case .text:
            (annotation.text as NSString).draw(at: first, withAttributes: [
                .font: NSFont.systemFont(ofSize: annotation.width * 5 + 12, weight: .semibold),
                .foregroundColor: annotation.color,
            ])
        }
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        let scale = CGFloat(image.width) / bounds.width
        return CGPoint(x: min(max(0, local.x * scale), CGFloat(image.width)),
                       y: min(max(0, local.y * scale), CGFloat(image.height)))
    }

    private func makeMosaicTiles() -> CGImage? {
        MosaicFilter.makeTiles(from: image, blockSize: max(8, Int(lineWidth * 4))) { context in
            // Include earlier edits so another mosaic never restores source pixels
            // over an existing redaction. Store only this small bitmap with the edit.
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            for annotation in annotations { draw(annotation, in: context) }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = imagePoint(event)
        if tool == .text { requestText?(point); return }
        draft = Annotation(tool: tool, points: [point], color: ink, width: lineWidth)
        if tool == .mosaic { draft?.mosaicTiles = makeMosaicTiles() }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var annotation = draft else { return }
        let point = imagePoint(event)
        if tool == .pen { annotation.points.append(point) }
        else { annotation.points = [annotation.points[0], point] }
        draft = annotation
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard var completed = draft else { return }
        self.draft = nil
        needsDisplay = true
        if completed.tool == .mosaic || completed.tool == .redact {
            let end = imagePoint(event)
            guard let start = completed.points.first, start.x != end.x, start.y != end.y else { return }
            completed.points = [start, end]
        }
        if completed.tool == .pen || completed.points.count > 1 { replaceAnnotations(annotations + [completed]) }
    }

    func addText(_ text: String, at point: CGPoint) {
        guard !text.isEmpty else { return }
        replaceAnnotations(annotations + [Annotation(tool: .text, points: [point], color: ink, width: lineWidth, text: text)])
    }

    func clear() { replaceAnnotations([]) }

    private func replaceAnnotations(_ next: [Annotation]) {
        let previous = annotations
        editHistory.registerUndo(withTarget: self) { target in target.replaceAnnotations(previous) }
        annotations = next
        needsDisplay = true
        onChange?()
    }
}
