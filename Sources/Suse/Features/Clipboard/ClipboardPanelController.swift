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
    private let list: ClipboardListModel
    private var selectedEntry: ClipboardRecord?
    private var reloadTask: Task<Void, Never>?
    private var needsReload = false
    private var actionTask: Task<Void, Never>?
    private var contextRecord: ClipboardRecord?
    private static let rowDragType = NSPasteboard.PasteboardType("app.suse.clipboard-history-row")
    private var sourceApplication: NSRunningApplication?
    private var pasteTask: Task<Void, Never>?

    init(store: ClipboardStore, pins: (any PinPresenting)? = nil) {
        self.store = store
        list = ClipboardListModel(store: store)
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
        store.onChange = { [weak self] in self?.historyDidChange() }
        list.onPageLoaded = { [weak self] range in
            guard let self else { return }
            table.reloadData(forRowIndexes: IndexSet(integersIn: range), columnIndexes: IndexSet(integer: 0))
            updateSelection()
        }
        list.onError = { [weak self] in self?.showStorageError($0) }
        list.onInvalidated = { [weak self] in self?.historyDidChange() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func toggle() {
        if window?.isVisible == true { hide(); return }
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
        if window?.attachedSheet == nil { hide() }
    }

    func windowWillClose(_ notification: Notification) {
        actionTask?.cancel()
        reloadTask?.cancel()
        list.cancelRequests()
        needsReload = true
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
        table.registerForDraggedTypes([Self.rowDragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        let contextMenu = NSMenu()
        contextMenu.autoenablesItems = false
        contextMenu.delegate = self
        let stickyItem = NSMenuItem(title: "置顶", action: #selector(togglePinnedFromContextMenu), keyEquivalent: "")
        stickyItem.target = self
        contextMenu.addItem(stickyItem)
        contextMenu.addItem(.separator())
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

    private func reload() {
        needsReload = false
        reloadTask?.cancel()
        let query = search.stringValue
        let selectedID = selectedEntry?.id
        reloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let selectedRow = try await list.refresh(query: query, selectedID: selectedID)
                try Task.checkCancellation()
                table.reloadData()
                emptyState.isHidden = list.total > 0
                emptyState.stringValue = query.isEmpty ? "还没有剪贴板记录\n复制一段文字或图片，它会出现在这里。" : "没有匹配的内容"
                if let selectedRow {
                    table.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
                } else {
                    table.deselectAll(nil)
                }
                updateSelection()
                updateStatus()
            } catch is CancellationError { }
            catch { showStorageError(error) }
        }
    }

    private func historyDidChange() {
        if window?.isVisible == true { reload() }
        else { needsReload = true }
    }

    /// Also prepares an offscreen panel for layout and integration checks.
    func waitForReload() async {
        await store.flush()
        if needsReload { reload() }
        await reloadTask?.value
    }
    func waitForAction() async { await actionTask?.value }

    private func updateStatus() {
        status.stringValue = "\(list.total) 条记录  ·  ↑↓ 选择  ·  ↩ 复制  ·  ⌘↩ 粘贴  ·  ⌘E 编辑  ·  ⌘P Pin"
        if let notice = store.accessNotice { status.stringValue = notice }
        if let error = store.persistenceError { status.stringValue = "历史存储失败：\(error)" }
    }

    private func showStorageError(_ error: Error) {
        status.stringValue = "历史读取失败：\(error.localizedDescription)"
        status.toolTip = error.localizedDescription
    }

    func controlTextDidChange(_ notification: Notification) {
        actionTask?.cancel()
        selectedEntry = nil
        reload()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { list.total }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ClipboardRowView.reuseIdentifier, owner: self) as? ClipboardRowView
            ?? ClipboardRowView()
        cell.configure(with: list.record(at: row))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }

    private func updateSelection() {
        let record = list.record(at: table.selectedRow)
        if record?.id != selectedEntry?.id { actionTask?.cancel() }
        selectedEntry = record
    }

    private func hide() {
        actionTask?.cancel()
        window?.orderOut(nil)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 53: hide()
        case 125, 126:
            guard list.total > 0 else { return true }
            let index = min(max(table.selectedRow + (event.keyCode == 125 ? 1 : -1), 0), list.total - 1)
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
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        contextRecord = list.record(at: row)
        menu.items.first?.title = contextRecord?.isPinned == true ? "取消置顶" : "置顶"
        menu.items.first?.isEnabled = contextRecord != nil
        menu.items.last?.isEnabled = pins != nil && contextRecord != nil
    }

    @objc private func togglePinnedFromContextMenu() {
        guard let record = contextRecord else { return }
        selectedEntry = record
        store.setPinned(record, pinned: !record.isPinned)
    }

    @objc private func pinFromContextMenu() {
        guard let record = contextRecord else { return }
        selectedEntry = record
        pinSelected()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard search.stringValue.isEmpty, let record = list.record(at: row), record.isPinned else { return nil }
        let item = NSPasteboardItem()
        item.setString(record.id.uuidString, forType: Self.rowDragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard search.stringValue.isEmpty, info.draggingSource as? NSTableView === table,
              info.draggingPasteboard.string(forType: Self.rowDragType) != nil,
              isPinnedDropBoundary(row) else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard search.stringValue.isEmpty, info.draggingSource as? NSTableView === table,
              let value = info.draggingPasteboard.string(forType: Self.rowDragType), let id = UUID(uuidString: value),
              isPinnedDropBoundary(row) else { return false }
        let next = list.record(at: row)
        store.movePinned(id: id, before: next?.isPinned == true ? next?.id : nil)
        return true
    }

    private func isPinnedDropBoundary(_ row: Int) -> Bool {
        guard row >= 0, row <= list.total else { return false }
        if row < list.total {
            guard let next = list.record(at: row) else { return false }
            if next.isPinned { return true }
        }
        // The boundary immediately after the last pinned row is a valid drop target too.
        return row > 0 && list.record(at: row - 1)?.isPinned == true
    }

    func pinSelected() {
        guard let pins else { NSSound.beep(); return }
        loadSelected { [weak self] entry, _ in
            guard let self else { return }
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
    }

    private func commit(paste: Bool) {
        let expectedChangeCount = store.pasteboardChangeCount
        let destination = sourceApplication
        loadSelected { [weak self] entry, _ in
            guard let self else { return }
            guard store.copy(entry, expectedChangeCount: expectedChangeCount) else {
                UI.error(AppError("剪贴板已改变或写入失败，请重新选择后复制。"), in: window)
                return
            }
            window?.orderOut(nil)
            guard paste else { return }
            let writtenChangeCount = store.pasteboardChangeCount
            pasteTask = Task { [weak self] in
                guard let self else { return }
                do { try await pasteService.paste(to: destination, expectedChangeCount: writtenChangeCount) }
                catch is CancellationError { }
                catch { UI.error(error) }
            }
        }
    }

    private func loadSelected(_ action: @escaping @MainActor (ClipboardEntry, ClipboardRecord) -> Void) {
        guard let record = selectedEntry else { NSSound.beep(); return }
        actionTask?.cancel()
        status.stringValue = "正在读取内容…"
        actionTask = Task { [weak self, store] in
            do {
                let entry = try await store.content(for: record)
                try Task.checkCancellation()
                guard let self, selectedEntry?.id == record.id else { return }
                updateStatus()
                action(entry, record)
            } catch is CancellationError { }
            catch { self?.showStorageError(error) }
        }
    }

    private func editSelected() {
        guard selectedEntry?.isImage == false else { NSSound.beep(); return }
        loadSelected { [weak self] entry, record in
            guard let self, case .text(let text) = entry.content else { return }
            presentEditor(text: text, record: record)
        }
    }

    private func presentEditor(text: String, record: ClipboardRecord) {
        guard let parent = window else { return }
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
        var saving = false
        let save = ActionButton("保存") { [weak self] in
            guard let self, !saving else { return }
            let text = editor.string
            guard !text.isEmpty else { UI.error(AppError("文本内容不能为空。"), in: sheet); return }
            saving = true
            editor.isEditable = false
            Task {
                defer { saving = false; editor.isEditable = true }
                if await store.edit(record, text: text) { parent.endSheet(sheet) }
                else { UI.error(AppError(store.persistenceError ?? "保存失败，请重试。"), in: sheet) }
            }
        }
        save.keyEquivalent = "\r"
        save.keyEquivalentModifierMask = [.command]
        let cancel = ActionButton("取消") { if !saving { parent.endSheet(sheet) } }
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
