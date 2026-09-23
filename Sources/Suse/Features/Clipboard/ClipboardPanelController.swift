import AppKit
import SuseCore

@MainActor
private final class HistoryPanel: NSPanel {
    var handleKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        let composing = (firstResponder as? NSTextView)?.hasMarkedText() == true
        if event.type == .keyDown, !composing, attachedSheet == nil, handleKey?(event) == true { return }
        super.sendEvent(event)
    }
}

@MainActor
final class ClipboardPanelController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
                                      NSSearchFieldDelegate, NSWindowDelegate, NSToolbarDelegate, NSMenuDelegate {
    private let store: ClipboardStore
    private let pins: (any PinPresenting)?
    private let pasteService = PasteService()
    private let table = NSTableView()
    private let search = NSSearchField()
    private let searchItem = NSSearchToolbarItem(itemIdentifier: .init("clipboard.search"))
    private let emptyState = UI.label("还没有剪贴板记录\n复制一段文字或图片，它会出现在这里。", size: 14, color: .secondaryLabelColor)
    private let status = UI.label("", size: 11, color: .secondaryLabelColor)
    private var visibleEntries: [ClipboardEntry] = []
    private var sourceApplication: NSRunningApplication?
    private var pasteTask: Task<Void, Never>?

    init(store: ClipboardStore, pins: (any PinPresenting)? = nil) {
        self.store = store
        self.pins = pins
        let panel = HistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 490),
                                 styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "剪贴板"
        panel.toolbarStyle = .unifiedCompact
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        panel.handleKey = { [weak self] in self?.handleKey($0) ?? false }
        build()
        store.onChange = { [weak self] in self?.reload() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func toggle() {
        if window?.isVisible == true { window?.orderOut(nil); return }
        pasteTask?.cancel()
        sourceApplication = NSWorkspace.shared.frontmostApplication
        search.stringValue = ""
        reload()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        searchItem.beginSearchInteraction()
    }

    func windowDidResignKey(_ notification: Notification) {
        if window?.attachedSheet == nil { window?.orderOut(nil) }
    }

    private func build() {
        search.placeholderString = "搜索历史内容"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.controlSize = .regular
        searchItem.searchField = search
        searchItem.preferredWidthForSearchField = 360
        searchItem.resignsFirstResponderWithCancel = false
        let toolbar = NSToolbar(identifier: "clipboard")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 58
        table.intercellSpacing = NSSize(width: 0, height: 3)
        table.style = .inset
        table.backgroundColor = .controlBackgroundColor
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(copySelected)
        table.setAccessibilityLabel("剪贴板历史记录")
        let contextMenu = NSMenu()
        contextMenu.autoenablesItems = false
        contextMenu.delegate = self
        let pinItem = NSMenuItem(title: "Pin", action: #selector(pinFromContextMenu), keyEquivalent: "")
        pinItem.target = self
        contextMenu.addItem(pinItem)
        table.menu = contextMenu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        let list = NSView()
        list.addSubview(scroll)
        UI.pin(scroll, to: list)
        list.addSubview(emptyState)
        emptyState.alignment = .center
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: list.centerYAnchor),
        ])
        let pin = ActionButton("Pin", symbol: "pin", style: .glass) { [weak self] in self?.pinSelected() }
        pin.isEnabled = pins != nil
        pin.toolTip = "Pin 选中的内容（⌘P）"
        let actions = UI.stack([
            ActionButton("复制", symbol: "doc.on.doc", style: .glass) { [weak self] in self?.commit(paste: false) },
            ActionButton("粘贴到原应用", symbol: "arrow.turn.down.left", style: .glass) { [weak self] in self?.commit(paste: true) },
            ActionButton("编辑", symbol: "pencil", style: .glass) { [weak self] in self?.editSelected() },
            pin,
        ], axis: .horizontal, spacing: 8)
        let footer = UI.stack([UI.glassContainer(actions), status], spacing: 8)
        let content = ContentBackgroundView()
        content.addSubview(list)
        content.addSubview(footer)
        list.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor, constant: 4),
            list.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            list.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            list.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            list.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        window?.contentView = content
        reload()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, searchItem.itemIdentifier] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [searchItem.itemIdentifier] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        itemIdentifier == searchItem.itemIdentifier ? searchItem : nil
    }

    private var selectedEntry: ClipboardEntry? {
        visibleEntries.indices.contains(table.selectedRow) ? visibleEntries[table.selectedRow] : nil
    }

    private func reload() {
        let selectedID = selectedEntry?.id
        visibleEntries = store.history.entries.filter { $0.matches(search.stringValue) }
        table.reloadData()
        emptyState.isHidden = !visibleEntries.isEmpty
        emptyState.stringValue = search.stringValue.isEmpty ? "还没有剪贴板记录\n复制一段文字或图片，它会出现在这里。" : "没有匹配的内容"
        if !visibleEntries.isEmpty {
            let index = visibleEntries.firstIndex(where: { $0.id == selectedID }) ?? 0
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        status.stringValue = "\(visibleEntries.count) 条记录  ·  ↑↓ 选择  ·  ↩ 复制  ·  ⌘↩ 粘贴  ·  ⌘E 编辑  ·  ⌘P Pin"
        if let notice = store.accessNotice { status.stringValue = notice }
        if let error = store.persistenceError { status.stringValue = "历史保存失败：\(error)" }
    }

    func controlTextDidChange(_ notification: Notification) { reload() }
    func numberOfRows(in tableView: NSTableView) -> Int { visibleEntries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = visibleEntries[row]
        let image: NSImage
        if case .image(let data) = entry.content { image = ImageThumbnail.make(from: data) ?? NSImage() }
        else { image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "文本")! }
        let icon = NSImageView(image: image)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let title = UI.label(entry.title.isEmpty ? "空白文本" : entry.title, size: 13, weight: .medium)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        let subtitle = UI.label("\(entry.source) · \(entry.capturedAt.formatted(date: .omitted, time: .shortened))", size: 11, color: .secondaryLabelColor)
        let rowView = UI.stack([icon, UI.stack([title, subtitle], spacing: 3)], axis: .horizontal, spacing: 10)
        rowView.setAccessibilityLabel("\(entry.title)，来自 \(entry.source)")
        return rowView
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 53: window?.orderOut(nil)
        case 125, 126:
            guard !visibleEntries.isEmpty else { return true }
            let index = min(max(table.selectedRow + (event.keyCode == 125 ? 1 : -1), 0), visibleEntries.count - 1)
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        case 36, 76: commit(paste: command)
        case 14 where command: editSelected()
        case 35 where event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command]: pinSelected()
        case 3 where command: searchItem.beginSearchInteraction()
        case 51 where command:
            if let entry = selectedEntry { store.remove(entry) }
        default: return false
        }
        return true
    }

    @objc private func copySelected() { commit(paste: false) }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.first?.isEnabled = pins != nil && visibleEntries.indices.contains(table.clickedRow)
    }

    @objc private func pinFromContextMenu() {
        guard visibleEntries.indices.contains(table.clickedRow) else { return }
        table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        pinSelected()
    }

    func pinSelected() {
        guard let entry = selectedEntry, let pins else { NSSound.beep(); return }
        let content: PinRequest.Content
        switch entry.content {
        case .text(let text): content = .text(text)
        case .image(let data): content = .imageData(data, scale: window?.screen?.backingScaleFactor ?? 1)
        }
        do {
            try pins.pin(PinRequest(content: content, source: .clipboard(entry.id)))
            window?.orderOut(nil)
            sourceApplication?.activate()
        } catch {
            status.stringValue = "Pin 失败：\(error.localizedDescription)"
            status.toolTip = error.localizedDescription
        }
    }

    private func commit(paste: Bool) {
        guard let entry = selectedEntry else { NSSound.beep(); return }
        guard store.copy(entry) else { UI.error(AppError("系统剪贴板写入失败，请重试。"), in: window); return }
        window?.orderOut(nil)
        guard paste else { return }
        let destination = sourceApplication
        let expectedChangeCount = NSPasteboard.general.changeCount
        pasteTask = Task { [weak self] in
            guard let self else { return }
            do { try await pasteService.paste(to: destination, expectedChangeCount: expectedChangeCount) }
            catch is CancellationError { }
            catch { UI.error(error) }
        }
    }

    private func editSelected() {
        guard let entry = selectedEntry, case .text(let text) = entry.content, let parent = window else {
            NSSound.beep(); return
        }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 380),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "编辑历史内容"
        let editor = NSTextView()
        editor.isRichText = false
        editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.string = text
        editor.isAutomaticQuoteSubstitutionEnabled = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.documentView = editor
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        let save = ActionButton("保存") { [weak self] in
            guard let self else { return }
            guard store.edit(entry, text: editor.string) else {
                UI.error(AppError("内容不能为空，且不能超过 8 MB。"), in: sheet); return
            }
            parent.endSheet(sheet)
        }
        save.keyEquivalent = "\r"
        save.keyEquivalentModifierMask = [.command]
        let cancel = ActionButton("取消") { parent.endSheet(sheet) }
        cancel.keyEquivalent = "\u{1b}"
        let content = UI.stack([UI.label("编辑文本", size: 18, weight: .semibold), scroll,
                                UI.stack([cancel, save], axis: .horizontal)], spacing: 16)
        scroll.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 250).isActive = true
        sheet.contentView = UI.padded(content)
        parent.beginSheet(sheet)
        sheet.makeFirstResponder(editor)
    }
}
