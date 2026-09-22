import AppKit
import UniformTypeIdentifiers

@MainActor
final class AnnotationWindowController: NSWindowController, NSWindowDelegate {
    private let canvas: AnnotationCanvas
    private let status = UI.label("", size: 12, color: .secondaryLabelColor)
    private let scroll = NSScrollView()
    private let toolPicker = NSSegmentedControl()
    private let colorWell = NSColorWell()
    var onClose: (() -> Void)?

    init(image: CGImage) {
        let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
        let width = min(1050, available.width - 80)
        let height = min(800, available.height - 80)
        canvas = AnnotationCanvas(image: image, displayWidth: min(width - 40, CGFloat(image.width)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "截图 · 标注"
        window.minSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        canvas.requestText = { [weak self] in self?.requestText(at: $0) }
        canvas.onChange = { [weak self] in self?.updateStatus() }
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func show() { window?.center(); showWindow(nil); NSApp.activate(); updateStatus() }
    func windowWillClose(_ notification: Notification) { onClose?() }

    private func build() {
        toolPicker.segmentCount = AnnotationTool.allCases.count
        toolPicker.trackingMode = .selectOne
        toolPicker.segmentStyle = .rounded
        for tool in AnnotationTool.allCases {
            toolPicker.setLabel(tool.title, forSegment: tool.rawValue)
            toolPicker.setImage(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title), forSegment: tool.rawValue)
        }
        toolPicker.selectedSegment = AnnotationTool.arrow.rawValue
        toolPicker.target = self
        toolPicker.action = #selector(toolChanged)
        colorWell.color = .systemRed
        colorWell.colorWellStyle = .minimal
        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        colorWell.widthAnchor.constraint(equalToConstant: 32).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let widths = NSSegmentedControl(labels: ["细", "中", "粗"], trackingMode: .selectOne, target: self, action: #selector(widthChanged(_:)))
        widths.selectedSegment = 1
        let toolbar = UI.stack([toolPicker, colorWell, widths], axis: .horizontal, spacing: 14)
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 4
        scroll.borderType = .noBorder
        let copy = ActionButton("复制图片", symbol: "doc.on.doc") { [weak self] in self?.copyImage() }
        copy.keyEquivalent = "c"
        copy.keyEquivalentModifierMask = [.command, .shift]
        let save = ActionButton("保存 PNG…", symbol: "square.and.arrow.down") { [weak self] in self?.saveImage() }
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = [.command]
        let footer = UI.stack([
            ActionButton("撤销", symbol: "arrow.uturn.backward") { [weak self] in self?.canvas.undoManager?.undo() },
            ActionButton("重做", symbol: "arrow.uturn.forward") { [weak self] in self?.canvas.undoManager?.redo() },
            ActionButton("清除标注") { [weak self] in self?.canvas.clear() },
            copy, save,
        ], axis: .horizontal, spacing: 10)
        let content = UI.stack([UI.glass(toolbar, radius: 14, inset: 10), scroll, footer, status], spacing: 14)
        let background = NSView()
        background.addSubview(content)
        UI.pin(content, to: background, inset: 20)
        scroll.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        content.alignment = .leading
        window?.contentView = background
    }

    @objc private func toolChanged() {
        canvas.tool = AnnotationTool(rawValue: toolPicker.selectedSegment) ?? .arrow
        canvas.window?.invalidateCursorRects(for: canvas)
    }
    @objc private func colorChanged() { canvas.ink = colorWell.color }
    @objc private func widthChanged(_ sender: NSSegmentedControl) { canvas.lineWidth = [2, 5, 10][sender.selectedSegment] }

    private func updateStatus() {
        status.stringValue = "\(canvas.image.width) × \(canvas.image.height) px · \(canvas.annotationCount) 处标注 · 双指缩放 · ⇧⌘C 复制 · ⌘S 保存"
    }

    func copyImage() {
        do {
            let png = try pngData()
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setData(png, forType: .png) else { throw AppError("剪贴板写入失败。") }
            status.stringValue = "已复制标注后的图片"
        } catch { UI.error(error, in: window) }
    }

    private func pngData() throws -> Data {
        let image = try canvas.renderedImage()
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw AppError("无法编码 PNG 图片。")
        }
        return data
    }

    private func saveImage() {
        guard let window else { return }
        let save = NSSavePanel()
        save.allowedContentTypes = [.png]
        save.nameFieldStringValue = "Suse-\(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "-" )).png"
        save.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = save.url, let self else { return }
            do { try pngData().write(to: url, options: .atomic); status.stringValue = "已保存到 \(url.lastPathComponent)" }
            catch { UI.error(error, in: window) }
        }
    }

    private func requestText(at point: CGPoint) {
        guard let window else { return }
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
