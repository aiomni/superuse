import AppKit
import UniformTypeIdentifiers

enum CaptureReviewAction { case scroll, reselect, done }

@MainActor
private final class CaptureReviewView: NSView {
    var onCopy: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

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
    private let status = UI.label("", size: 12, color: .secondaryLabelColor)
    private let scroll = NSScrollView()
    private let toolPicker = NSSegmentedControl()
    private let colorWell = NSColorWell()
    private var toolbar: NSView?
    private var palette: NSView?
    private var editButton: ActionButton?
    private var scrollButton: ActionButton?
    var onAction: ((CaptureReviewAction) -> Void)?

    init(image: CGImage, selectionRect: CGRect, displaySize: CGSize, allowsScrolling: Bool,
         pasteboard: NSPasteboard = .general) {
        self.selectionRect = selectionRect
        self.displaySize = displaySize
        self.allowsScrolling = allowsScrolling
        self.pasteboard = pasteboard
        canvas = AnnotationCanvas(image: image, displayWidth: selectionRect.width)
        canvas.editingEnabled = false
        super.init(nibName: nil, bundle: nil)
        canvas.requestText = { [weak self] in self?.requestText(at: $0) }
        canvas.onChange = { [weak self] in self?.updateStatus() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let content = CaptureReviewView(frame: CGRect(origin: .zero, size: displaySize))
        content.onCopy = { [weak self] in self?.copyImage(completing: false) }
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
        buildToolbar()
        updateStatus()
    }

    private func buildToolbar() {
        let edit = ActionButton("编辑", symbol: "pencil.tip", style: .toolbar) { [weak self] in self?.toggleEditing() }
        editButton = edit
        let scrolling = ActionButton("滚动截图", symbol: "scroll", style: .toolbar) { [weak self] in self?.onAction?(.scroll) }
        scrolling.isHidden = !allowsScrolling
        scrollButton = scrolling
        let copy = ActionButton("复制并完成", symbol: "checkmark", style: .glass) { [weak self] in self?.copyImage(completing: true) }
        copy.keyEquivalent = "\r"
        copy.keyEquivalentModifierMask = []
        let save = ActionButton("保存…", symbol: "square.and.arrow.down", style: .toolbar) { [weak self] in self?.saveImage() }
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = [.command]
        let actions = UI.stack([
            scrolling, edit,
            ActionButton("重选", symbol: "crop", style: .toolbar) { [weak self] in self?.onAction?(.reselect) },
            save,
            ActionButton(icon: "取消", symbol: "xmark") { [weak self] in self?.onAction?(.done) },
        ], axis: .horizontal, spacing: 8)
        let palette = UI.glassBar(makePalette())
        palette.isHidden = true
        self.palette = palette
        let mainBar = UI.glassBar(UI.stack([actions, status], spacing: 5))
        let content = UI.stack([palette, UI.stack([mainBar, copy], axis: .horizontal, spacing: 10)], spacing: 8)
        content.alignment = .trailing
        let container = UI.glassContainer(content)
        view.addSubview(container)
        toolbar = container
        positionToolbar()
    }

    private func makePalette() -> NSView {
        toolPicker.segmentCount = AnnotationTool.allCases.count
        toolPicker.trackingMode = .selectOne
        toolPicker.segmentStyle = .rounded
        for tool in AnnotationTool.allCases {
            toolPicker.setImage(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title), forSegment: tool.rawValue)
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
        colorWell.widthAnchor.constraint(equalToConstant: 28).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let widths = NSSegmentedControl(labels: ["细", "中", "粗"], trackingMode: .selectOne,
                                        target: self, action: #selector(widthChanged(_:)))
        widths.selectedSegment = 1
        return UI.stack([
            toolPicker, colorWell, widths,
            ActionButton(icon: "撤销", symbol: "arrow.uturn.backward") { [weak self] in self?.canvas.undoManager?.undo() },
            ActionButton(icon: "重做", symbol: "arrow.uturn.forward") { [weak self] in self?.canvas.undoManager?.redo() },
            ActionButton(icon: "清除标注", symbol: "trash") { [weak self] in self?.canvas.clear() },
        ], axis: .horizontal, spacing: 8)
    }

    private func positionToolbar() {
        guard let toolbar else { return }
        toolbar.layoutSubtreeIfNeeded()
        let size = toolbar.fittingSize
        let margin: CGFloat = 12
        let x = min(max(margin, selectionRect.maxX - size.width), max(margin, displaySize.width - size.width - margin))
        let y: CGFloat
        if selectionRect.maxY + margin + size.height <= displaySize.height - margin {
            y = selectionRect.maxY + margin
        } else if selectionRect.minY - margin - size.height >= margin {
            y = selectionRect.minY - margin - size.height
        } else {
            y = max(margin, displaySize.height - size.height - margin)
        }
        toolbar.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private func toggleEditing() {
        canvas.editingEnabled.toggle()
        palette?.isHidden = !canvas.editingEnabled
        editButton?.title = canvas.editingEnabled ? "完成标注" : "编辑"
        editButton?.setAccessibilityLabel(editButton?.title)
        canvas.window?.invalidateCursorRects(for: canvas)
        view.window?.makeFirstResponder(canvas.editingEnabled ? canvas : view)
        updateStatus()
        positionToolbar()
    }

    @objc private func toolChanged() {
        canvas.tool = AnnotationTool(rawValue: toolPicker.selectedSegment) ?? .arrow
        canvas.window?.invalidateCursorRects(for: canvas)
    }
    @objc private func colorChanged() { canvas.ink = colorWell.color }
    @objc private func widthChanged(_ sender: NSSegmentedControl) { canvas.lineWidth = [2, 5, 10][sender.selectedSegment] }

    private func updateStatus() {
        let hint = canvas.editingEnabled ? "\(canvas.annotationCount) 处标注 · ⇧⌘C 复制" : "Enter 完成 · ⌘S 保存"
        status.stringValue = "\(canvas.image.width) × \(canvas.image.height) px · \(hint)"
        scrollButton?.isEnabled = !canvas.editingEnabled && canvas.annotationCount == 0
        scrollButton?.toolTip = canvas.annotationCount > 0 ? "清除标注后可进入滚动截图" : "进入后在选区内缓慢向下滚动"
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
            status.stringValue = "已复制 · \(canvas.image.width) × \(canvas.image.height) px"
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
                status.stringValue = "已保存到 \(url.lastPathComponent)"
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
