import AppKit
import SuseCore
import UniformTypeIdentifiers

enum CaptureReviewAction { case scroll, reselect, pinned, done }

@MainActor
private final class CaptureReviewView: NSView {
    var onCopy: (() -> Void)?
    var onBackgroundClick: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) { onBackgroundClick?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 8 && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift] {
            onCopy?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Reviews and edits the crop at its original screen position.
@MainActor
final class CaptureReviewController: NSViewController {
    private let canvas: AnnotationCanvas
    private(set) var selectionRect: CGRect
    private let displaySize: CGSize
    private let allowsScrolling: Bool
    private let pasteboard: NSPasteboard
    private let onPin: ((CGImage) throws -> Void)?
    private let sourceImage: CGImage?
    private let copyAfterAdjustment: Bool
    private var hasBegunAnnotation = false
    private var regionAdjustment: CaptureRegionAdjustmentView?
    private let status = UI.label("", size: 12, weight: .medium)
    private let statusBadge = NSBox()
    private let scroll = NSScrollView()
    private let toolPicker = NSSegmentedControl()
    private let colorWell = NSColorWell()
    private let widths = NSSegmentedControl()
    private var toolbar: NSView?
    private var toolbarContent: NSStackView?
    private var palette: NSView?
    private var toolbarAnchor = CGPoint.zero
    private var toolbarBelowSelection = false
    private var scrollButton: ActionButton?
    var onAction: ((CaptureReviewAction) -> Void)?
    var onRegionChange: ((CGRect) -> Void)?

    init(image: CGImage, selectionRect: CGRect, displaySize: CGSize, allowsScrolling: Bool,
         pasteboard: NSPasteboard = .general, onPin: ((CGImage) throws -> Void)? = nil,
         sourceImage: CGImage? = nil, copyAfterAdjustment: Bool = false) {
        self.selectionRect = selectionRect
        self.displaySize = displaySize
        self.allowsScrolling = allowsScrolling
        self.pasteboard = pasteboard
        self.onPin = onPin
        self.sourceImage = sourceImage
        self.copyAfterAdjustment = copyAfterAdjustment
        canvas = AnnotationCanvas(image: image, displayWidth: selectionRect.width, pasteboard: pasteboard)
        if sourceImage != nil { canvas.tool = .select }
        super.init(nibName: nil, bundle: nil)
        canvas.onChange = { [weak self] in self?.updateStatus() }
        canvas.onSelectionChange = { [weak self] in self?.updatePalette() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let content = CaptureReviewView(frame: CGRect(origin: .zero, size: displaySize))
        content.onCopy = { [weak self] in self?.copyImage(completing: false) }
        content.onBackgroundClick = { [weak self] in self?.canvas.finishTextEditing() }
        view = content
        scroll.frame = selectionRect
        scroll.documentView = canvas
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = CGFloat(canvas.image.height) / CGFloat(canvas.image.width) > selectionRect.height / selectionRect.width + 0.01
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.borderWidth = 2
        scroll.layer?.borderColor = NSColor.controlAccentColor.cgColor
        view.addSubview(scroll)
        if sourceImage != nil {
            let adjustment = CaptureRegionAdjustmentView(rect: selectionRect, displaySize: displaySize)
            adjustment.onChange = { [weak self] rect, finished in self?.adjustRegion(to: rect, finished: finished) }
            view.addSubview(adjustment)
            regionAdjustment = adjustment
        }
        buildStatusBadge()
        buildToolbar()
    }

    private func buildToolbar() {
        let scrolling = ActionButton("滚动截图", symbol: "scroll", style: .accessoryBar) { [weak self] in
            guard let self else { return }
            canvas.finishTextEditing()
            if canvas.annotationCount == 0 { onAction?(.scroll) }
        }
        scrolling.isHidden = !allowsScrolling
        scrollButton = scrolling
        let copy = ActionButton("完成", symbol: "checkmark", symbolColor: .systemGreen, style: .accessoryBar) { [weak self] in self?.copyImage(completing: true) }
        copy.keyEquivalent = "\r"
        copy.keyEquivalentModifierMask = []
        copy.toolTip = "复制当前截图并退出（↩）"
        copy.setAccessibilityLabel("复制并完成")
        let save = ActionButton(icon: "保存", symbol: "square.and.arrow.down", style: .accessoryBar) { [weak self] in self?.saveImage() }
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = [.command]
        save.toolTip = "保存截图（⌘S）"
        let pin = ActionButton("Pin", symbol: "pin", style: .accessoryBar) { [weak self] in self?.pinImage() }
        pin.keyEquivalent = "p"
        pin.keyEquivalentModifierMask = [.command]
        pin.toolTip = "Pin 当前截图并退出（⌘P）"
        pin.isEnabled = onPin != nil
        let reselect = ActionButton(icon: "重选", symbol: "crop", style: .accessoryBar) { [weak self] in self?.onAction?(.reselect) }
        let cancel = ActionButton(icon: "取消", symbol: "xmark", symbolColor: .systemRed, style: .accessoryBar) { [weak self] in self?.onAction?(.done) }
        cancel.toolTip = "取消截图（Esc）"
        let actions = UI.stack([
            scrolling,
            UI.stack([reselect, save, pin], axis: .horizontal, spacing: 8),
            UI.stack([cancel, copy], axis: .horizontal, spacing: 8),
        ], axis: .horizontal, spacing: 16)
        let palette = UI.glassBar(makePalette(), inset: 8)
        self.palette = palette
        let mainBar = UI.glassBar(actions, inset: 8)
        let content = UI.stack([palette, mainBar], spacing: 8)
        toolbarContent = content
        content.alignment = .trailing
        let container = UI.glassContainer(content)
        view.addSubview(container)
        toolbar = container
        updateStatus()
        anchorToolbar(content: content, palette: palette)
        positionToolbar()
    }

    private func buildStatusBadge() {
        status.usesSingleLineMode = true
        status.lineBreakMode = .byTruncatingTail
        status.setAccessibilityIdentifier("capture-status")
        status.widthAnchor.constraint(lessThanOrEqualToConstant: min(320, displaySize.width - 40)).isActive = true
        statusBadge.boxType = .custom
        statusBadge.titlePosition = .noTitle
        statusBadge.borderWidth = 0
        statusBadge.cornerRadius = 8
        statusBadge.fillColor = .windowBackgroundColor
        statusBadge.contentViewMargins = .zero
        statusBadge.contentView = UI.padded(status, inset: 6)
        view.addSubview(statusBadge)
    }

    private func positionStatusBadge() {
        statusBadge.layoutSubtreeIfNeeded()
        let size = statusBadge.fittingSize
        let margin: CGFloat = 8
        let x = min(max(margin, selectionRect.minX), displaySize.width - size.width - margin)
        let candidates = [selectionRect.minY - size.height - margin, selectionRect.maxY + margin, selectionRect.minY + margin]
        var frames = candidates.map { CGRect(x: x, y: $0, width: size.width, height: size.height) }
        if let toolbar {
            // Small corner selections may leave no room beside the full action bar.
            // Move feedback around the controls without moving either toolbar anchor.
            frames.append(CGRect(x: x, y: toolbar.frame.maxY + margin, width: size.width, height: size.height))
            frames.append(CGRect(x: x, y: toolbar.frame.minY - size.height - margin, width: size.width, height: size.height))
            frames.append(CGRect(x: toolbar.frame.maxX + margin, y: margin, width: size.width, height: size.height))
        }
        statusBadge.frame = frames.first {
            view.bounds.contains($0) && !(toolbar?.frame.intersects($0) ?? false)
        } ?? CGRect(x: x, y: margin, width: size.width, height: size.height)
    }

    private func makePalette() -> NSView {
        toolPicker.segmentCount = AnnotationTool.allCases.count
        toolPicker.trackingMode = .selectOne
        toolPicker.segmentStyle = .roundRect
        toolPicker.setAccessibilityLabel("标注工具")
        for tool in AnnotationTool.allCases {
            let image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
            toolPicker.setImage(image, forSegment: tool.rawValue)
            toolPicker.setToolTip(tool.tooltip, forSegment: tool.rawValue)
            toolPicker.setWidth(32, forSegment: tool.rawValue)
        }
        toolPicker.selectedSegment = canvas.tool.rawValue
        toolPicker.target = self
        toolPicker.action = #selector(toolChanged)
        colorWell.color = .systemRed
        colorWell.colorWellStyle = .minimal
        colorWell.setAccessibilityLabel("标注颜色")
        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        colorWell.widthAnchor.constraint(equalToConstant: 24).isActive = true
        colorWell.heightAnchor.constraint(equalTo: colorWell.widthAnchor).isActive = true
        widths.segmentCount = 3
        widths.trackingMode = .selectOne
        widths.target = self
        widths.action = #selector(widthChanged(_:))
        for (index, title) in ["细", "中", "粗"].enumerated() { widths.setLabel(title, forSegment: index) }
        widths.segmentStyle = .roundRect
        widths.setAccessibilityLabel("标注大小")
        widths.font = .systemFont(ofSize: 13, weight: .medium)
        widths.toolTip = "调整选中标注或新标注的线条粗细、字号、马赛克颗粒大小"
        widths.selectedSegment = 1
        let undo = ActionButton(icon: "撤销", symbol: "arrow.uturn.backward", style: .accessoryBar) { [weak self] in self?.canvas.undoEdit() }
        undo.keyEquivalent = "z"
        undo.keyEquivalentModifierMask = [.command]
        undo.toolTip = "撤销（⌘Z）"
        let redo = ActionButton(icon: "重做", symbol: "arrow.uturn.forward", style: .accessoryBar) { [weak self] in self?.canvas.undoEdit(redo: true) }
        redo.keyEquivalent = "Z"
        redo.keyEquivalentModifierMask = [.command, .shift]
        redo.toolTip = "重做（⇧⌘Z）"
        return UI.stack([
            toolPicker, colorWell, widths, undo, redo,
            ActionButton(icon: "清除标注", symbol: "trash", style: .accessoryBar) { [weak self] in self?.canvas.clear() },
        ], axis: .horizontal, spacing: 8)
    }

    private func anchorToolbar(content: NSStackView, palette: NSView) {
        guard let toolbar else { return }
        // Place both control bars together and retain their anchor throughout the review.
        // The anchor is the main bar's right edge and its top or bottom edge.
        toolbar.layoutSubtreeIfNeeded()
        let size = toolbar.fittingSize
        let margin: CGFloat = 12
        toolbarBelowSelection = false
        content.removeArrangedSubview(palette)
        content.insertArrangedSubview(palette, at: 0)
        let x = min(max(margin, selectionRect.maxX - size.width), max(margin, displaySize.width - size.width - margin))
        toolbarAnchor.x = x + size.width
        if selectionRect.maxY + margin + size.height <= displaySize.height - margin {
            toolbarBelowSelection = true
            toolbarAnchor.y = selectionRect.maxY + margin
            content.removeArrangedSubview(palette)
            content.addArrangedSubview(palette)
        } else if selectionRect.minY - margin - size.height >= margin {
            toolbarAnchor.y = selectionRect.minY - margin
        } else {
            toolbarAnchor.y = max(margin + size.height, displaySize.height - margin)
        }
    }

    private func positionToolbar() {
        guard let toolbar else { return }
        toolbar.layoutSubtreeIfNeeded()
        let size = toolbar.fittingSize
        let x = toolbarAnchor.x - size.width
        let y = toolbarBelowSelection ? toolbarAnchor.y : toolbarAnchor.y - size.height
        toolbar.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        positionStatusBadge()
    }

    @objc private func toolChanged() {
        canvas.tool = AnnotationTool(rawValue: toolPicker.selectedSegment) ?? .arrow
        regionAdjustment?.allowsMove = canvas.tool == .select
        updatePalette()
        canvas.window?.invalidateCursorRects(for: canvas)
    }
    @objc private func colorChanged() { canvas.setInk(colorWell.color) }
    @objc private func widthChanged(_ sender: NSSegmentedControl) { canvas.setLineWidth([2, 5, 10][sender.selectedSegment]) }

    private func updatePalette() {
        let selected = canvas.selectedAnnotation
        let tool = selected?.tool ?? canvas.tool
        colorWell.color = selected?.color ?? canvas.ink
        colorWell.isEnabled = tool != .mosaic && tool != .redact && tool != .emoji
        widths.isEnabled = tool != .redact
        widths.selectedSegment = [CGFloat(2), 5, 10].firstIndex(of: selected?.width ?? canvas.lineWidth) ?? -1
    }

    private func updateStatus() {
        if canvas.annotationCount > 0 || canvas.textEditor != nil { hasBegunAnnotation = true }
        regionAdjustment?.isHidden = hasBegunAnnotation
        let annotations = canvas.annotationCount > 0 ? " · \(canvas.annotationCount) 处标注" : ""
        setStatus("\(canvas.image.width) × \(canvas.image.height) px\(annotations)")
        status.toolTip = sourceImage != nil && !hasBegunAnnotation
            ? "标注前：选择工具拖动内部移动截图区域，拖动四边或四角调整宽高；点击标注工具开始编辑"
            : "选择工具可移动、缩放标注 · 双击文字编辑 · 输入时 ↩ 换行、⌘↩ 结束输入 · ⌘S 保存 · Esc 退出"
        scrollButton?.isEnabled = canvas.annotationCount == 0
        scrollButton?.toolTip = canvas.annotationCount > 0 ? "撤销或清除全部标注后可进入滚动截图" : "进入后在选区内缓慢向下滚动"
    }

    private func setStatus(_ message: String) {
        status.stringValue = message
        positionStatusBadge()
    }

    private func adjustRegion(to rect: CGRect, finished: Bool) {
        guard let sourceImage, !hasBegunAnnotation else { return }
        if rect != selectionRect {
            let crop = ScreenGeometry.pixelCrop(selection: rect, displayFrame: CGRect(origin: .zero, size: displaySize),
                                                pixelSize: CGSize(width: sourceImage.width, height: sourceImage.height))
            guard !crop.isEmpty, let image = sourceImage.cropping(to: crop) else { return }
            selectionRect = rect
            scroll.frame = rect
            canvas.replaceBaseImage(image, displayWidth: rect.width)
            scroll.contentView.scroll(to: .zero)
            regionAdjustment?.selectionRect = rect
            onRegionChange?(rect)
            updateStatus()
        }
        if finished {
            if let toolbarContent, let palette { anchorToolbar(content: toolbarContent, palette: palette) }
            positionToolbar()
            if copyAfterAdjustment { copyImage(completing: false) }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        positionToolbar()
    }

    func copyImage(completing: Bool) {
        do {
            let png = try pngData()
            pasteboard.clearContents()
            guard pasteboard.setData(png, forType: .png) else { throw AppError("剪贴板写入失败。") }
            setStatus("已复制 · \(canvas.image.width) × \(canvas.image.height) px")
            if completing { onAction?(.done) }
        } catch { UI.error(error, in: view.window) }
    }

    func pinImage() {
        guard let onPin else { return }
        do {
            try onPin(canvas.renderedImage())
            onAction?(.pinned)
        } catch {
            setStatus("Pin 失败：\(error.localizedDescription)")
            status.toolTip = error.localizedDescription
        }
    }

    private func pngData() throws -> Data {
        let image = try canvas.renderedImage()
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw AppError("无法编码 PNG 图片。")
        }
        return data
    }

    private func saveImage() {
        guard let window = view.window else { return }
        let save = NSSavePanel()
        save.allowedContentTypes = [.png]
        save.nameFieldStringValue = "\(AppIdentity.name)-\(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "-")).png"
        save.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = save.url, let self else { return }
            do {
                try pngData().write(to: url, options: .atomic)
                setStatus("已保存到 \(url.lastPathComponent)")
            } catch { UI.error(error, in: window) }
        }
    }

}
