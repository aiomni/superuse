import AppKit
import SuseCore

@MainActor
final class AnnotationCanvas: NSView, NSTextViewDelegate {
    private(set) var image: CGImage
    var tool: AnnotationTool = .arrow {
        didSet {
            guard oldValue != tool else { return }
            finishTextEditing()
            select(nil)
            window?.invalidateCursorRects(for: self)
        }
    }
    var ink = NSColor.systemRed
    var lineWidth: CGFloat = 5
    var onChange: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    var showEmojiPicker: () -> Void = { NSApp.orderFrontCharacterPalette(nil) }
    private let pasteboard: NSPasteboard
    private(set) var annotations: [ScreenshotAnnotation] = []
    private(set) var selectedID: UUID?
    private(set) var textEditor: AnnotationTextView?
    private var editingAnnotation: ScreenshotAnnotation?
    private var editingWindowLevel: NSWindow.Level?
    private var draft: ScreenshotAnnotation?
    private var manipulation: Manipulation?
    private let textWidthHandles = [AnnotationTextWidthHandle(fromLeft: true), AnnotationTextWidthHandle(fromLeft: false)]
    private let editHistory = UndoManager()

    private struct Manipulation {
        let original: [ScreenshotAnnotation]
        let annotation: ScreenshotAnnotation
        let start: CGPoint
        let handle: Int?
        var editing = false
        var changed = false
    }

    override var undoManager: UndoManager? { editHistory }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var annotationCount: Int {
        annotations.count + (editingAnnotation.map { edit in
            !annotations.contains { $0.id == edit.id } && !(textEditor?.string.isEmpty ?? true) ? 1 : 0
        } ?? 0)
    }
    var selectedAnnotation: ScreenshotAnnotation? {
        editingAnnotation ?? annotations.first { $0.id == selectedID }
    }
    private var imageSize: CGSize { CGSize(width: image.width, height: image.height) }
    private var displayScale: CGFloat { bounds.width / CGFloat(image.width) }

    init(image: CGImage, displayWidth: CGFloat, pasteboard: NSPasteboard = .general) {
        self.image = image
        self.pasteboard = pasteboard
        super.init(frame: CGRect(x: 0, y: 0, width: displayWidth,
                                height: displayWidth * CGFloat(image.height) / CGFloat(image.width)))
        editHistory.groupsByEvent = false
        for handle in textWidthHandles {
            handle.isHidden = true
            handle.onMouseDown = { [weak self, weak handle] event in
                guard let self, let handle else { return }
                beginTextWidthResize(fromLeft: handle.fromLeft, event: event)
            }
            handle.onMouseDragged = { [weak self] in self?.mouseDragged(with: $0) }
            handle.onMouseUp = { [weak self] in self?.mouseUp(with: $0) }
            addSubview(handle)
        }
        setAccessibilityLabel("截图标注画布")
        setAccessibilityHelp("使用选择工具移动、缩放标注；双击文字编辑，Delete 删除选中标注。")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Re-crop the frozen source only before this canvas has any editing history.
    func replaceBaseImage(_ image: CGImage, displayWidth: CGFloat) {
        precondition(annotations.isEmpty && textEditor == nil && draft == nil && !editHistory.canUndo && !editHistory.canRedo)
        self.image = image
        setFrameSize(CGSize(width: displayWidth, height: displayWidth * CGFloat(image.height) / CGFloat(image.width)))
        needsDisplay = true
    }
    override func resetCursorRects() {
        let cursor: NSCursor = tool == .select ? .arrow : (tool == .text || tool == .emoji ? .iBeam : .crosshair)
        addCursorRect(bounds, cursor: cursor)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.scaleBy(x: displayScale, y: displayScale)
        render(in: context, preview: true)
        if textEditor == nil, let selected = selectedAnnotation { drawSelection(selected, in: context) }
        context.restoreGState()
    }

    func renderedImage() throws -> CGImage {
        finishTextEditing()
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AppError("图片过大，无法创建导出画布。")
        }
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        render(in: context, preview: false)
        NSGraphicsContext.restoreGraphicsState()
        guard let result = context.makeImage() else { throw AppError("无法生成图片。") }
        return result
    }

    private func render(in context: CGContext, preview: Bool) {
        drawBitmap(image, in: context)
        for annotation in annotations where !preview || annotation.id != editingAnnotation?.id {
            draw(annotation, in: context)
        }
        if preview, let draft { draw(draft, in: context) }
    }

    private func drawBitmap(_ bitmap: CGImage, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(bitmap, in: CGRect(origin: .zero, size: imageSize))
        context.restoreGState()
    }

    private func draw(_ annotation: ScreenshotAnnotation, in context: CGContext) {
        guard let first = annotation.points.first else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(annotation.color.cgColor)
        context.setFillColor(annotation.color.cgColor)
        context.setLineWidth(max(0.1, annotation.width))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let rect = annotation.bounds
        switch annotation.tool {
        case .pen:
            if annotation.points.count == 1 {
                context.fillEllipse(in: CGRect(x: first.x - annotation.width / 2, y: first.y - annotation.width / 2,
                                              width: annotation.width, height: annotation.width))
            } else { context.addLines(between: annotation.points); context.strokePath() }
        case .arrow:
            context.addLines(between: annotation.points)
            context.addLines(between: annotation.arrowhead)
            context.strokePath()
        case .rectangle: context.stroke(rect)
        case .ellipse: context.strokeEllipse(in: rect)
        case .redact:
            context.setFillColor(NSColor.black.cgColor)
            context.fill(rect.integral)
        case .mosaic:
            context.clip(to: rect.integral)
            // Never expose source pixels on transparent input or allocation failure.
            context.setFillColor(NSColor.black.cgColor)
            context.fill(rect.integral)
            if let tiles = annotation.mosaicTiles {
                context.interpolationQuality = .none
                drawBitmap(tiles, in: context)
            }
        case .text:
            annotation.attributedText.draw(with: annotation.textLayoutBounds, options: [.usesLineFragmentOrigin, .usesFontLeading])
        case .select, .emoji: break
        }
    }

    private func drawSelection(_ annotation: ScreenshotAnnotation, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1 / displayScale)
        context.setLineDash(phase: 0, lengths: [4 / displayScale, 3 / displayScale])
        context.stroke(annotation.selectionBounds.insetBy(dx: -2 / displayScale, dy: -2 / displayScale))
        context.setLineDash(phase: 0, lengths: [])
        context.setFillColor(NSColor.controlBackgroundColor.cgColor)
        let side = 7 / displayScale
        for (index, point) in annotation.handles.enumerated() where annotation.tool != .text || index < 4 {
            let rect = CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
            context.fill(rect)
            context.stroke(rect)
        }
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(0, local.x / displayScale), imageSize.width),
                       y: min(max(0, local.y / displayScale), imageSize.height))
    }

    private func rebuildingMosaics(_ source: [ScreenshotAnnotation]) -> [ScreenshotAnnotation] {
        var result: [ScreenshotAnnotation] = []
        for var annotation in source {
            if annotation.tool == .mosaic {
                let previous = result
                annotation.mosaicTiles = MosaicFilter.makeTiles(from: image, blockSize: max(8, Int(annotation.width * 4))) { context in
                    NSGraphicsContext.saveGraphicsState()
                    defer { NSGraphicsContext.restoreGraphicsState() }
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                    for earlier in previous { draw(earlier, in: context) }
                }
            }
            result.append(annotation)
        }
        return result
    }

    override func mouseDown(with event: NSEvent) {
        finishTextEditing()
        window?.makeFirstResponder(self)
        let point = imagePoint(event)
        if tool != .select, event.clickCount == 1, let selected = selectedAnnotation,
           let handle = selected.handles.firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) <= 8 / displayScale }) {
            manipulation = Manipulation(original: annotations, annotation: selected, start: point, handle: handle)
            return
        }
        if tool == .select {
            let handle = selectedAnnotation?.handles.firstIndex { hypot($0.x - point.x, $0.y - point.y) <= 8 / displayScale }
            if handle == nil { select(annotations.last { $0.contains(point, tolerance: 5 / displayScale) }?.id) }
            if let selected = selectedAnnotation {
                if selected.tool == .text && event.clickCount == 2 {
                    beginTextEditing(selected)
                } else {
                    manipulation = Manipulation(original: annotations, annotation: selected, start: point, handle: handle)
                }
            }
            return
        }
        if tool == .text || tool == .emoji {
            if tool == .text, let existing = annotations.last(where: { $0.tool == .text && $0.contains(point, tolerance: 0) }) {
                beginTextEditing(existing)
            } else {
                beginTextEditing(newText("", at: point))
            }
            if tool == .emoji { showEmojiPicker() }
            return
        }
        select(nil)
        draft = ScreenshotAnnotation(tool: tool, points: [point], color: ink, width: lineWidth)
        if tool == .mosaic, let draft { self.draft = rebuildingMosaics(annotations + [draft]).last }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if manipulation != nil { updateManipulation(to: imagePoint(event)); return }
        updateDraft(to: imagePoint(event))
    }

    private func updateDraft(to point: CGPoint) {
        guard var annotation = draft else { return }
        if annotation.tool == .pen {
            if annotation.points.last != point { annotation.points.append(point) }
        } else { annotation.points = [annotation.points[0], point] }
        draft = annotation
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = imagePoint(event)
        if manipulation != nil {
            updateManipulation(to: point)
            guard let manipulation else { return }
            self.manipulation = nil
            if manipulation.editing {
                if manipulation.changed { registerTextLayoutUndo(manipulation.annotation) }
                return
            }
            let next = annotations
            annotations = manipulation.original
            if manipulation.changed { replaceAnnotations(next, selected: selectedID) }
            return
        }
        updateDraft(to: point)
        guard let completed = draft else { return }
        draft = nil
        needsDisplay = true
        if completed.tool == .mosaic || completed.tool == .redact {
            guard completed.bounds.width > 0, completed.bounds.height > 0 else { return }
        } else if completed.tool != .pen {
            guard completed.bounds.width + completed.bounds.height > 2 / displayScale else { return }
        }
        replaceAnnotations(annotations + [completed])
    }

    private func updateManipulation(to point: CGPoint) {
        guard var gesture = manipulation else { return }
        // A click selects without registering an undo step or shifting the annotation.
        guard gesture.changed || hypot(point.x - gesture.start.x, point.y - gesture.start.y) * displayScale >= 2 else { return }
        gesture.changed = true
        var annotation = gesture.annotation
        if let handle = gesture.handle {
            if annotation.tool == .text && handle >= 4 {
                let old = annotation.textLayoutBounds
                let minimum = min(24 / displayScale, handle == 4 ? old.maxX : imageSize.width - old.minX)
                let edge = handle == 4 ? old.minX : old.maxX
                let x = min(imageSize.width, max(0, edge + point.x - gesture.start.x))
                let next = AnnotationGeometry.resizingWidth(old, fromLeft: handle == 4, to: x, minimum: minimum)
                annotation.points = [next.origin]
                annotation.textWidth = next.width
            } else if annotation.tool == .arrow {
                annotation.points[handle == 0 ? 0 : annotation.points.count - 1] = point
            } else {
                let old = annotation.selectionBounds
                let next = AnnotationGeometry.resizing(old, corner: handle, to: point, minimum: 8 / displayScale)
                if annotation.tool == .text {
                    let factor = max(8 / annotation.fontSize, min(next.width / old.width, next.height / old.height))
                    annotation.width = (annotation.fontSize * factor - 12) / 5
                    annotation.textWidth *= factor
                    let opposite = AnnotationGeometry.corners(of: old)[(handle + 2) % 4]
                    let size = annotation.textLayoutBounds.size
                    annotation.points = [CGPoint(x: handle == 0 || handle == 3 ? opposite.x - size.width : opposite.x,
                                                 y: handle == 0 || handle == 1 ? opposite.y - size.height : opposite.y)]
                } else {
                    annotation.points = AnnotationGeometry.mapping(annotation.points, from: old, to: next)
                }
            }
        } else {
            let delta = AnnotationGeometry.clampedTranslation(CGPoint(x: point.x - gesture.start.x, y: point.y - gesture.start.y),
                                                             bounds: annotation.selectionBounds, within: imageSize)
            annotation.points = annotation.points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
        }
        if gesture.editing {
            guard editingAnnotation?.id == annotation.id else { return }
            editingAnnotation?.points = annotation.points
            editingAnnotation?.textWidth = annotation.textWidth
            layoutTextEditor()
        } else {
            guard let index = gesture.original.firstIndex(where: { $0.id == annotation.id }) else { return }
            var next = gesture.original
            next[index] = annotation
            annotations = rebuildingMosaics(next)
        }
        manipulation = gesture
        needsDisplay = true
        updateTextWidthHandles()
    }

    private func beginTextWidthResize(fromLeft: Bool, event: NSEvent) {
        guard let annotation = selectedAnnotation, annotation.tool == .text else { return }
        textEditor?.breakUndoCoalescing()
        manipulation = Manipulation(original: annotations, annotation: annotation, start: imagePoint(event),
                                    handle: fromLeft ? 4 : 5, editing: textEditor != nil)
        if textEditor == nil { window?.makeFirstResponder(self) }
    }

    private func registerTextLayoutUndo(_ previous: ScreenshotAnnotation) {
        guard let editor = textEditor else { return }
        editor.breakUndoCoalescing()
        editor.undoManager?.beginUndoGrouping()
        editor.undoManager?.registerUndo(withTarget: self) { target in target.restoreTextLayout(previous) }
        editor.undoManager?.endUndoGrouping()
    }

    private func restoreTextLayout(_ previous: ScreenshotAnnotation) {
        guard let current = editingAnnotation, current.id == previous.id else { return }
        registerTextLayoutUndo(current)
        editingAnnotation?.points = previous.points
        editingAnnotation?.textWidth = previous.textWidth
        layoutTextEditor()
    }

    private func updateTextWidthHandles() {
        for (index, handle) in textWidthHandles.enumerated() {
            guard let selected = selectedAnnotation, selected.tool == .text else { handle.isHidden = true; continue }
            let point = selected.handles[index + 4]
            let inset = bounds.insetBy(dx: min(4, bounds.width / 2), dy: min(8, bounds.height / 2))
            let x = min(max(point.x * displayScale, inset.minX), inset.maxX)
            let y = min(max(point.y * displayScale, inset.minY), inset.maxY)
            handle.frame = CGRect(x: x - 9, y: y - 11, width: 18, height: 22)
            handle.isHidden = false
        }
    }

    private func select(_ id: UUID?) {
        selectedID = id
        needsDisplay = true
        updateTextWidthHandles()
        onSelectionChange?()
    }

    func setInk(_ color: NSColor) {
        ink = color
        updateSelected { annotation in
            if annotation.tool != .mosaic && annotation.tool != .redact { annotation.color = color }
        }
    }

    func setLineWidth(_ width: CGFloat) {
        lineWidth = width
        updateSelected { annotation in
            if annotation.tool != .redact { annotation.width = width }
        }
    }

    private func updateSelected(_ update: (inout ScreenshotAnnotation) -> Void) {
        if var edit = editingAnnotation {
            update(&edit)
            editingAnnotation = edit
            updateTextEditorStyle()
        } else if let index = annotations.firstIndex(where: { $0.id == selectedID }) {
            var next = annotations
            update(&next[index])
            replaceAnnotations(next, selected: selectedID)
        }
        onSelectionChange?()
    }

    override func keyDown(with event: NSEvent) {
        if [UInt16(51), 117].contains(event.keyCode),
           event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty {
            deleteSelected()
        } else { super.keyDown(with: event) }
    }

    func deleteSelected() {
        finishTextEditing()
        guard let selectedID else { return }
        replaceAnnotations(annotations.filter { $0.id != selectedID })
    }

    func undoEdit(redo: Bool = false) {
        if let textEditor { textEditor.undoTyping(redo: redo) }
        else if redo { if editHistory.canRedo { editHistory.redo() } }
        else if editHistory.canUndo { editHistory.undo() }
    }

    private func newText(_ text: String, at point: CGPoint) -> ScreenshotAnnotation {
        let width = min(320 / displayScale, imageSize.width)
        let origin = CGPoint(x: min(point.x, max(0, imageSize.width - min(width, 120 / displayScale))),
                             y: min(point.y, max(0, imageSize.height - (lineWidth * 5 + 12) * 1.3)))
        return ScreenshotAnnotation(tool: .text, points: [origin], color: ink, width: lineWidth,
                                    text: text, textWidth: min(width, imageSize.width - origin.x))
    }

    func addText(_ text: String, at point: CGPoint) {
        finishTextEditing()
        guard !text.isEmpty else { return }
        replaceAnnotations(annotations + [newText(text, at: point)])
    }

    private func beginTextEditing(_ annotation: ScreenshotAnnotation) {
        editingAnnotation = annotation
        select(annotation.id)
        let editor = AnnotationTextView(frame: .zero)
        editor.annotationPasteboard = pasteboard
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.containerSize.height = .greatestFiniteMagnitude
        editor.drawsBackground = true
        editor.backgroundColor = .textBackgroundColor
        editor.wantsLayer = true
        editor.layer?.borderColor = NSColor.controlAccentColor.cgColor
        editor.layer?.borderWidth = 1
        editor.string = annotation.text
        editor.delegate = self
        editor.onFinish = { [weak self] in self?.finishTextEditing() }
        editor.setAccessibilityLabel("标注文字（支持 emoji）")
        editor.setAccessibilityHelp("直接输入文字或表情，拖动左右控制点调整换行宽度；Return 换行，Command Return 结束输入。")
        textEditor = editor
        addSubview(editor, positioned: .below, relativeTo: textWidthHandles.first)
        updateTextEditorStyle()
        // Native IME candidates and the system character picker must remain above the frozen overlay.
        if let window, window.level.rawValue > NSWindow.Level.floating.rawValue {
            editingWindowLevel = window.level
            window.level = .floating
        }
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        onChange?()
    }

    private func updateTextEditorStyle() {
        guard let editor = textEditor, let annotation = editingAnnotation else { return }
        editor.font = .systemFont(ofSize: annotation.fontSize * displayScale, weight: .semibold)
        editor.textColor = annotation.color
        editor.insertionPointColor = .labelColor
        layoutTextEditor()
    }

    private func layoutTextEditor() {
        guard let editor = textEditor, let annotation = editingAnnotation else { return }
        let rect = annotation.textLayoutBounds
        editor.frame = CGRect(x: rect.minX * displayScale, y: rect.minY * displayScale,
                              width: rect.width * displayScale,
                              height: max(24, rect.height * displayScale + 4))
        editor.textContainer?.containerSize = CGSize(width: editor.bounds.width, height: .greatestFiniteMagnitude)
        if let container = editor.textContainer, let layout = editor.layoutManager {
            layout.ensureLayout(for: container)
            editor.setFrameSize(CGSize(width: editor.frame.width,
                                       height: max(editor.frame.height, ceil(layout.usedRect(for: container).height) + 4)))
        }
        editor.scrollRangeToVisible(editor.selectedRange())
        updateTextWidthHandles()
    }

    func textDidChange(_ notification: Notification) {
        guard let editor = textEditor, notification.object as? NSTextView === editor else { return }
        editingAnnotation?.text = editor.string
        layoutTextEditor()
        onChange?()
    }

    func finishTextEditing() {
        guard let editor = textEditor, var annotation = editingAnnotation else { return }
        editor.unmarkText()
        annotation.text = editor.string
        editor.delegate = nil
        editor.onFinish = nil
        textEditor = nil
        editingAnnotation = nil
        if window?.firstResponder === editor { window?.makeFirstResponder(self) }
        editor.removeFromSuperview()
        if let editingWindowLevel { window?.level = editingWindowLevel }
        editingWindowLevel = nil
        var next = annotations
        if let index = next.firstIndex(where: { $0.id == annotation.id }) {
            let original = next[index]
            if original.text == annotation.text && original.width == annotation.width && original.color == annotation.color &&
                original.textWidth == annotation.textWidth && original.points == annotation.points {
                select(annotation.id)
                return
            }
            if annotation.text.isEmpty { next.remove(at: index) }
            else { next[index] = annotation }
        } else if !annotation.text.isEmpty { next.append(annotation) }
        else { select(nil); onChange?(); return }
        replaceAnnotations(next, selected: annotation.text.isEmpty ? nil : annotation.id)
    }

    func clear() {
        finishTextEditing()
        guard !annotations.isEmpty else { return }
        replaceAnnotations([])
    }

    private func replaceAnnotations(_ next: [ScreenshotAnnotation], selected: UUID? = nil) {
        let previous = annotations
        let previousSelection = selectedID
        editHistory.beginUndoGrouping()
        editHistory.registerUndo(withTarget: self) { target in
            target.replaceAnnotations(previous, selected: previousSelection)
        }
        editHistory.endUndoGrouping()
        annotations = rebuildingMosaics(next)
        select(next.contains { $0.id == selected } ? selected : nil)
        onChange?()
    }
}
