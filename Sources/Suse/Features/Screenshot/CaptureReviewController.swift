import AppKit
import UniformTypeIdentifiers

enum CaptureReviewAction { case scroll, reselect, done }

@MainActor
private final class CaptureReviewView: NSView {
    var onCopy: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

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
    private let selectionRect: CGRect
    private let displaySize: CGSize
    private let allowsScrolling: Bool
    private let pasteboard: NSPasteboard
    private let status = UI.label("", size: 12, weight: .medium)
    private let statusBadge = NSBox()
    private let scroll = NSScrollView()
    private let toolPicker = NSSegmentedControl()
    private let colorWell = NSColorWell()
    private var toolbar: NSView?
    private var toolbarAnchor = CGPoint.zero
    private var toolbarBelowSelection = false
    private var scrollButton: ActionButton?
    var onAction: ((CaptureReviewAction) -> Void)?

    init(image: CGImage, selectionRect: CGRect, displaySize: CGSize, allowsScrolling: Bool,
         pasteboard: NSPasteboard = .general) {
        self.selectionRect = selectionRect
        self.displaySize = displaySize
        self.allowsScrolling = allowsScrolling
        self.pasteboard = pasteboard
        canvas = AnnotationCanvas(image: image, displayWidth: selectionRect.width)
        super.init(nibName: nil, bundle: nil)
        canvas.requestText = { [weak self] in self?.requestText(at: $0) }
        canvas.onChange = { [weak self] in self?.updateStatus() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let content = CaptureReviewView(frame: CGRect(origin: .zero, size: displaySize))
        content.onCopy = { [weak self] in self?.copyImage(completing: false) }
        content.onAppearanceChange = { [weak self] in self?.updateControlAppearance() }
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
        buildStatusBadge()
        buildToolbar()
        updateControlAppearance()
    }

    private func buildToolbar() {
        let scrolling = ActionButton("滚动截图", symbol: "scroll", style: .accessoryBar) { [weak self] in self?.onAction?(.scroll) }
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
        let reselect = ActionButton(icon: "重选", symbol: "crop", style: .accessoryBar) { [weak self] in self?.onAction?(.reselect) }
        let cancel = ActionButton(icon: "取消", symbol: "xmark", symbolColor: .systemRed, style: .accessoryBar) { [weak self] in self?.onAction?(.done) }
        cancel.toolTip = "取消截图（Esc）"
        let actions = UI.stack([
            scrolling,
            UI.stack([reselect, save], axis: .horizontal, spacing: 8),
            UI.stack([cancel, copy], axis: .horizontal, spacing: 8),
        ], axis: .horizontal, spacing: 16)
        let palette = UI.glassBar(makePalette(), inset: 8)
        let mainBar = UI.glassBar(actions, inset: 8)
        // A dark tint keeps bright desktop content from washing out control labels.
        palette.tintColor = .windowBackgroundColor
        mainBar.tintColor = .windowBackgroundColor
        let content = UI.stack([palette, mainBar], spacing: 8)
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

    private func updateControlAppearance() {
        // Capture controls keep a dark, readable surface over arbitrary desktop content.
        // Follow the parent's contrast setting without changing the captured image or sheets.
        let contrastAppearances: [NSAppearance.Name] = [
            .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
            .accessibilityHighContrastVibrantLight, .accessibilityHighContrastVibrantDark,
        ]
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            || contrastAppearances.contains(view.effectiveAppearance.name)
        let appearance = NSAppearance(named: highContrast ? .accessibilityHighContrastDarkAqua : .darkAqua)
        toolbar?.appearance = appearance
        statusBadge.appearance = appearance
    }

    private func positionStatusBadge() {
        statusBadge.layoutSubtreeIfNeeded()
        let size = statusBadge.fittingSize
        let margin: CGFloat = 8
        let x = min(max(margin, selectionRect.minX), displaySize.width - size.width - margin)
        let candidates = [selectionRect.minY - size.height - margin, selectionRect.maxY + margin, selectionRect.minY + margin]
        let frames = candidates.map { CGRect(x: x, y: $0, width: size.width, height: size.height) }
        statusBadge.frame = frames.first {
            view.bounds.contains($0) && !(toolbar?.frame.intersects($0) ?? false)
        } ?? CGRect(x: x, y: margin, width: size.width, height: size.height)
    }

    private func makePalette() -> NSView {
        toolPicker.segmentCount = AnnotationTool.allCases.count
        toolPicker.trackingMode = .selectOne
        toolPicker.segmentStyle = .roundRect
        for tool in AnnotationTool.allCases {
            let image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
            toolPicker.setImage(image, forSegment: tool.rawValue)
            toolPicker.setToolTip(tool.title, forSegment: tool.rawValue)
            toolPicker.setWidth(32, forSegment: tool.rawValue)
        }
        toolPicker.selectedSegment = AnnotationTool.arrow.rawValue
        toolPicker.target = self
        toolPicker.action = #selector(toolChanged)
        colorWell.color = .systemRed
        colorWell.colorWellStyle = .minimal
        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        colorWell.widthAnchor.constraint(equalToConstant: 24).isActive = true
        colorWell.heightAnchor.constraint(equalTo: colorWell.widthAnchor).isActive = true
        let widths = NSSegmentedControl(labels: ["细", "中", "粗"], trackingMode: .selectOne,
                                        target: self, action: #selector(widthChanged(_:)))
        widths.segmentStyle = .roundRect
        widths.font = .systemFont(ofSize: 13, weight: .medium)
        widths.selectedSegment = 1
        let undo = ActionButton(icon: "撤销", symbol: "arrow.uturn.backward", style: .accessoryBar) { [weak self] in self?.canvas.undoManager?.undo() }
        undo.keyEquivalent = "z"
        undo.keyEquivalentModifierMask = [.command]
        undo.toolTip = "撤销（⌘Z）"
        let redo = ActionButton(icon: "重做", symbol: "arrow.uturn.forward", style: .accessoryBar) { [weak self] in self?.canvas.undoManager?.redo() }
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
        canvas.window?.invalidateCursorRects(for: canvas)
    }
    @objc private func colorChanged() { canvas.ink = colorWell.color }
    @objc private func widthChanged(_ sender: NSSegmentedControl) { canvas.lineWidth = [2, 5, 10][sender.selectedSegment] }

    private func updateStatus() {
        let annotations = canvas.annotationCount > 0 ? " · \(canvas.annotationCount) 处标注" : ""
        setStatus("\(canvas.image.width) × \(canvas.image.height) px\(annotations)")
        status.toolTip = "↩ 完成 · ⌘S 保存 · ⇧⌘C 复制 · Esc 退出"
        scrollButton?.isEnabled = canvas.annotationCount == 0
        scrollButton?.toolTip = canvas.annotationCount > 0 ? "撤销或清除全部标注后可进入滚动截图" : "进入后在选区内缓慢向下滚动"
    }

    private func setStatus(_ message: String) {
        status.stringValue = message
        positionStatusBadge()
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

    private func requestText(at point: CGPoint) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "添加文字"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 350, height: 28))
        field.placeholderString = "输入标注内容"
        alert.accessoryView = field
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.canvas.addText(field.stringValue, at: point) }
        }
        alert.window.makeFirstResponder(field)
    }
}
