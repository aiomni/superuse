import AppKit
import SuseCore

@MainActor
final class PinPanel: NSPanel {
    var handleKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, attachedSheet == nil, handleKey?(event) == true { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if attachedSheet == nil, handleKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private final class PinImageView: NSImageView {
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

@MainActor
private final class PinTextView: NSTextView {
    var pinPasteboard: NSPasteboard = .general
    var copySelection: ((String) -> Bool)?

    override func copy(_ sender: Any?) {
        guard selectedRange().length > 0 else { return }
        _ = copySelection?((string as NSString).substring(with: selectedRange()))
    }

    override func cut(_ sender: Any?) {
        let range = selectedRange()
        guard isEditable, range.length > 0,
              copySelection?((string as NSString).substring(with: range)) == true else { return }
        insertText("", replacementRange: range)
    }

    override func paste(_ sender: Any?) {
        guard isEditable, let text = pinPasteboard.string(forType: .string) else { return }
        insertText(text, replacementRange: selectedRange())
    }

    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }
}

@MainActor
final class PinWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuDelegate, NSTextViewDelegate {
    private(set) var item: PinItem
    private let pasteboard: NSPasteboard
    private let scroll = NSScrollView()
    private let imageDocument = FlippedView()
    private let zoomItemID = NSToolbarItem.Identifier("pin.zoom")
    private let copyItemID = NSToolbarItem.Identifier("pin.copy")
    private let optionsItemID = NSToolbarItem.Identifier("pin.options")
    private static let imageInset: CGFloat = 16
    private var imageView: NSImageView?
    private(set) var textView: NSTextView?
    private var scale: CGFloat = 1
    private var previousViewportWidth: CGFloat = 0
    private var resizingProgrammatically = false
    private var opacity = 1.0
    private var clickThrough = false
    private var menuActions: [() -> Void] = []
    private var copyFeedbackTask: Task<Void, Never>?
    private weak var copyToolbarItem: NSToolbarItem?
    private let textUndoManager = UndoManager()
    private let editStatus = UI.label("", size: 11, color: .secondaryLabelColor)
    private lazy var editStatusContainer = UI.padded(editStatus, inset: 8)
    var onClose: (() -> Void)?
    var onOpacity: ((Double) -> Void)?
    var onClickThrough: ((Bool) -> Void)?
    var validateTextChange: ((String) throws -> Void)?
    var onTextChange: ((String) throws -> Void)?

    private var compactTitle: String {
        switch item.content {
        case .image: "图片 Pin"
        case .text: "文字 Pin"
        }
    }

    private static var textParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        return style
    }

    private static func preferredSize(for item: PinItem) -> CGSize {
        guard case .text(let text) = item.content else {
            return CGSize(width: max(440, item.pointSize.width + imageInset * 2),
                          height: item.pointSize.height + imageInset * 2)
        }
        // Measure a bounded sample: long notes scroll instead of growing the window indefinitely.
        let bounds = (String(text.prefix(4_000)) as NSString).boundingRect(
            with: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 14), .paragraphStyle: textParagraphStyle])
        return CGSize(width: 360, height: max(120, ceil(bounds.height) + 24))
    }

    init(item: PinItem, visibleFrame: CGRect, anchor: CGPoint, pasteboard: NSPasteboard = .general) {
        self.item = item
        self.pasteboard = pasteboard
        let frame = PinGeometry.initialFrame(contentSize: Self.preferredSize(for: item), on: visibleFrame, anchor: anchor)
        let panel = PinPanel(contentRect: frame, styleMask: [.titled, .nonactivatingPanel, .resizable, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
        panel.toolbarStyle = .unifiedCompact
        panel.titleVisibility = .hidden
        panel.tabbingMode = .disallowed
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.minSize = CGSize(width: min(PinGeometry.minimumSize.width, visibleFrame.width),
                               height: min(PinGeometry.minimumSize.height, visibleFrame.height))
        super.init(window: panel)
        panel.delegate = self
        panel.handleKey = { [weak self] in self?.handleKey($0) ?? false }
        build()
        panel.setFrame(frame, display: false)
        updateToolbarLayout()
        panel.contentView?.layoutSubtreeIfNeeded()
        previousViewportWidth = imageViewportWidth
        scale = min(1, previousViewportWidth / max(1, item.pointSize.width))
        updateImageLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    deinit { copyFeedbackTask?.cancel() }

    private func build() {
        window?.title = compactTitle
        let toolbar = NSToolbar(identifier: "pin")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        editStatus.setAccessibilityIdentifier("pin-edit-status")
        editStatusContainer.isHidden = true
        let content = UI.stack([scroll, editStatusContainer], spacing: 0)
        content.detachesHiddenViews = true
        scroll.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        editStatusContainer.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        window?.contentView = content
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        switch item.content {
        case .image(let image, let size):
            let view = PinImageView(image: NSImage(cgImage: image, size: size))
            view.imageScaling = .scaleAxesIndependently
            view.setAccessibilityLabel("Pin 图片，\(image.width) × \(image.height) 像素")
            imageView = view
            imageDocument.addSubview(view)
            scroll.documentView = imageDocument
            scroll.backgroundColor = .underPageBackgroundColor
            scroll.hasHorizontalScroller = true
        case .text(let text):
            let view = PinTextView(frame: CGRect(x: 0, y: 0, width: item.pointSize.width, height: item.pointSize.height))
            view.pinPasteboard = pasteboard
            view.copySelection = { [weak self] text in
                guard let self else { return false }
                do { return try write(text: text) }
                catch { showCopyFeedback(error: error); return false }
            }
            view.isRichText = false
            view.isEditable = true
            view.isSelectable = true
            view.allowsUndo = true
            textUndoManager.levelsOfUndo = 50
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.isAutomaticDashSubstitutionEnabled = false
            view.isAutomaticTextReplacementEnabled = false
            view.font = .systemFont(ofSize: 14)
            view.defaultParagraphStyle = Self.textParagraphStyle
            view.textColor = .textColor
            view.backgroundColor = .textBackgroundColor
            view.textContainerInset = CGSize(width: 20, height: 12)
            view.textContainer?.lineFragmentPadding = 0
            view.isVerticallyResizable = true
            view.isHorizontallyResizable = false
            view.autoresizingMask = [.width]
            view.minSize = .zero
            view.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            view.textContainer?.widthTracksTextView = true
            view.layoutManager?.allowsNonContiguousLayout = true
            view.string = text
            view.delegate = self
            view.setAccessibilityLabel("Pin 文字")
            textView = view
            scroll.documentView = view
        }
        window?.toolbar = toolbar
    }

    func apply(_ state: PinItem, visible: Bool) {
        item = state
        if case .text(let text) = state.content, let textView, !textView.hasMarkedText(), textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            textUndoManager.removeAllActions()
        }
        opacity = state.opacity
        clickThrough = state.isClickThrough
        window?.alphaValue = opacity
        window?.ignoresMouseEvents = clickThrough
        window?.title = clickThrough ? "鼠标穿透 · \(compactTitle)" : compactTitle
        scroll.toolTip = clickThrough ? "通过菜单栏 → 管理 Pin → 恢复全部操作，重新操作此窗口。" : nil
        if clickThrough, window?.isKeyWindow == true { window?.resignKey() }
        if visible {
            if window?.isVisible == false { window?.orderFrontRegardless() }
        } else { window?.orderOut(nil) }
    }

    func focus() {
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        if let textView { window?.makeFirstResponder(textView) }
    }

    func recover(on screens: [CGRect]) {
        guard let window else { return }
        let frame = PinGeometry.recover(window.frame, screens: screens)
        if frame != window.frame { window.setFrame(frame, display: true) }
    }

    func windowWillClose(_ notification: Notification) {
        copyFeedbackTask?.cancel()
        textUndoManager.removeAllActions()
        onClose?()
    }

    func undoManager(for view: NSTextView) -> UndoManager? { textUndoManager }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        guard let replacementString else { return true }
        let current = textView.string as NSString
        guard affectedCharRange.location <= current.length,
              affectedCharRange.length <= current.length - affectedCharRange.location else { return false }
        do {
            try validateTextChange?(current.replacingCharacters(in: affectedCharRange, with: replacementString))
            editStatusContainer.isHidden = true
            return true
        } catch {
            showEditError(error)
            return false
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let textView, notification.object as? NSTextView === textView else { return }
        do {
            try onTextChange?(textView.string)
            editStatusContainer.isHidden = true
        } catch {
            // Undo/IME changes may bypass preflight. Preserve the last accepted snapshot on rejection.
            if case .text(let accepted) = item.content {
                let location = min(textView.selectedRange().location, (accepted as NSString).length)
                textView.string = accepted
                textView.setSelectedRange(NSRange(location: location, length: 0))
                textUndoManager.removeAllActions()
            }
            showEditError(error)
        }
    }

    private func showEditError(_ error: Error) {
        editStatus.stringValue = error.localizedDescription
        editStatusContainer.isHidden = false
    }

    func windowDidResize(_ notification: Notification) {
        updateToolbarLayout()
        guard !resizingProgrammatically, imageView != nil else { return }
        window?.contentView?.layoutSubtreeIfNeeded()
        let width = imageViewportWidth
        if previousViewportWidth > 0 { scale = min(8, max(0.05, scale * width / previousViewportWidth)) }
        previousViewportWidth = width
        updateImageLayout()
    }

    private func updateToolbarLayout() {
        guard let window, let group = window.toolbar?.items.first(where: { $0.itemIdentifier == zoomItemID }) else { return }
        // Small references keep one menu instead of an overflow menu containing another menu.
        group.isHidden = window.frame.width < 480
    }

    private func updateImageLayout() {
        guard let imageView else { return }
        let size = CGSize(width: item.pointSize.width * scale, height: item.pointSize.height * scale)
        let canvas = CGSize(width: max(scroll.contentSize.width, size.width + Self.imageInset * 2),
                            height: max(scroll.contentSize.height, size.height + Self.imageInset * 2))
        imageDocument.setFrameSize(canvas)
        imageView.frame = CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                                 width: size.width, height: size.height)
        let origin = scroll.contentView.bounds.origin
        scroll.contentView.scroll(to: CGPoint(x: min(max(0, origin.x), max(0, canvas.width - scroll.contentSize.width)),
                                             y: min(max(0, origin.y), max(0, canvas.height - scroll.contentSize.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func setImageScale(_ value: CGFloat) {
        guard imageView != nil, value.isFinite, let window else { return }
        scale = min(8, max(0.05, value))
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let chromeHeight = window.frame.height - scroll.frame.height
        let size = CGSize(width: max(PinGeometry.minimumSize.width, item.pointSize.width * scale + Self.imageInset * 2),
                          height: max(PinGeometry.minimumSize.height, item.pointSize.height * scale + chromeHeight + Self.imageInset * 2))
        let frame = CGRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width, height: size.height)
        resizingProgrammatically = true
        window.setFrame(PinGeometry.constrain(frame, to: screen), display: true)
        updateToolbarLayout()
        window.contentView?.layoutSubtreeIfNeeded()
        previousViewportWidth = imageViewportWidth
        updateImageLayout()
        resizingProgrammatically = false
    }

    private func fitImage() {
        guard let window else { return }
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let chromeHeight = window.frame.height - scroll.frame.height
        setImageScale(min(1, min((screen.width * 0.75 - Self.imageInset * 2) / item.pointSize.width,
                                (screen.height * 0.75 - chromeHeight - Self.imageInset * 2) / item.pointSize.height)))
    }

    @discardableResult
    func copyAll() -> Bool {
        do {
            switch item.content {
            case .text(let text): return try write(text: textView?.string ?? text)
            case .image(let image, _):
                guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw AppError("无法编码图片。")
                }
                pasteboard.clearContents()
                guard pasteboard.setData(data, forType: .png) else { throw AppError("系统剪贴板写入失败。") }
                window?.title = "已复制"
                showCopyFeedback()
                return true
            }
        } catch { showCopyFeedback(error: error); return false }
    }

    private func write(text: String) throws -> Bool {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { throw AppError("系统剪贴板写入失败。") }
        window?.title = "已复制"
        showCopyFeedback()
        return true
    }

    private func showCopyFeedback(error: Error? = nil) {
        copyFeedbackTask?.cancel()
        copyToolbarItem?.image = NSImage(systemSymbolName: error == nil ? "checkmark" : "exclamationmark.triangle",
                                        accessibilityDescription: error == nil ? "已复制" : "复制失败")
        copyToolbarItem?.toolTip = error?.localizedDescription ?? "已复制"
        if error != nil { window?.title = "复制失败" }
        copyFeedbackTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            self?.copyToolbarItem?.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "复制")
            self?.copyToolbarItem?.toolTip = "复制完整内容（⌘C 复制选中的文字）"
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard !clickThrough, event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if let textView, window?.firstResponder === textView, !textView.hasMarkedText() {
            if event.keyCode == 6, modifiers == [.command] || modifiers == [.command, .shift] {
                textView.breakUndoCoalescing()
                if modifiers.contains(.shift) {
                    if textUndoManager.canRedo { textUndoManager.redo() }
                } else if textUndoManager.canUndo { textUndoManager.undo() }
                return true
            }
            if modifiers == [.command] {
                switch event.keyCode {
                case 0: textView.selectAll(nil); return true
                case 7: textView.cut(nil); return true
                case 9: textView.paste(nil); return true
                default: break
                }
            }
        }
        guard modifiers == [.command] else { return false }
        switch event.keyCode {
        case 13: window?.close()
        case 8:
            if let textView, window?.firstResponder === textView, textView.selectedRange().length > 0 {
                let text = (textView.string as NSString).substring(with: textView.selectedRange())
                do { _ = try write(text: text) }
                catch { showCopyFeedback(error: error) }
            } else { copyAll() }
        case 24 where imageView != nil: setImageScale(scale * 1.25)
        case 27 where imageView != nil: setImageScale(scale / 1.25)
        case 29 where imageView != nil: setImageScale(1)
        default: return false
        }
        return true
    }

    private var imageViewportWidth: CGFloat { max(1, scroll.contentSize.width - Self.imageInset * 2) }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        (imageView == nil ? [] : [zoomItemID]) + [.flexibleSpace, copyItemID, optionsItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == zoomItemID {
            let labels = ["缩小", "原始大小", "放大"]
            let images = zip(["minus.magnifyingglass", "1.magnifyingglass", "plus.magnifyingglass"], labels).map {
                NSImage(systemSymbolName: $0.0, accessibilityDescription: $0.1) ?? NSImage()
            }
            let group = NSToolbarItemGroup(itemIdentifier: identifier, images: images, selectionMode: .momentary,
                                          labels: labels, target: self, action: #selector(zoomImage(_:)))
            group.label = "缩放"
            group.isBordered = true
            group.visibilityPriority = .high
            return group
        }
        if identifier == copyItemID {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "复制"
            item.toolTip = "复制完整内容（⌘C 复制选中的文字）"
            item.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(copyContent)
            item.isBordered = true
            item.visibilityPriority = .user
            copyToolbarItem = item
            return item
        }
        if identifier == optionsItemID {
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = "更多"
            item.toolTip = "不透明度与鼠标穿透"
            item.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: item.label)
            item.showsIndicator = false
            item.isBordered = true
            item.menu = makeOptionsMenu()
            item.visibilityPriority = .user
            return item
        }
        return nil
    }

    @objc private func copyContent() { copyAll() }

    @objc private func zoomImage(_ sender: NSToolbarItemGroup) {
        switch sender.selectedIndex {
        case 0: setImageScale(scale / 1.25)
        case 1: setImageScale(1)
        case 2: setImageScale(scale * 1.25)
        default: break
        }
    }

    func makeOptionsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menuNeedsUpdate(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menuActions.removeAll()
        if imageView != nil {
            add("放大", to: menu) { [weak self] in guard let self else { return }; setImageScale(scale * 1.25) }
            add("缩小", to: menu) { [weak self] in guard let self else { return }; setImageScale(scale / 1.25) }
            add("原始大小", to: menu) { [weak self] in self?.setImageScale(1) }
            add("适应屏幕", to: menu) { [weak self] in self?.fitImage() }
            menu.addItem(.separator())
        }
        let opacityMenu = NSMenu()
        for value in [100, 80, 60, 40, 30] {
            let item = add("\(value)%", to: opacityMenu) { [weak self] in self?.onOpacity?(Double(value) / 100) }
            item.state = abs(opacity * 100 - Double(value)) < 0.5 ? .on : .off
        }
        let opacityItem = NSMenuItem(title: "不透明度", action: nil, keyEquivalent: "")
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)
        let through = add("鼠标穿透", to: menu) { [weak self] in self?.onClickThrough?(true) }
        through.toolTip = "开启后，从菜单栏「管理 Pin」恢复操作。"
        through.state = clickThrough ? .on : .off
    }

    @discardableResult
    private func add(_ title: String, to menu: NSMenu, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(invokeMenu(_:)), keyEquivalent: "")
        item.target = self
        item.tag = menuActions.count
        menuActions.append(action)
        menu.addItem(item)
        return item
    }

    @objc private func invokeMenu(_ sender: NSMenuItem) {
        guard menuActions.indices.contains(sender.tag) else { return }
        menuActions[sender.tag]()
    }
}
