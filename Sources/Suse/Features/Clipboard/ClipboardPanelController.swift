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
                                      NSSearchFieldDelegate, NSWindowDelegate {
    private let store: ClipboardStore
    private let pasteService = PasteService()
    private let table = NSTableView()
    private let search = NSSearchField()
    private let emptyState = UI.label("还没有剪贴板记录\n复制一段文字或图片，它会出现在这里。", size: 14, color: .secondaryLabelColor)
    private let status = UI.label("", size: 11, color: .secondaryLabelColor)
    private var visibleEntries: [ClipboardEntry] = []
    private var sourceApplication: NSRunningApplication?
    private var pasteTask: Task<Void, Never>?

    init(store: ClipboardStore) {
        self.store = store
        let panel = HistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 650, height: 520),
                                 styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "剪贴板历史"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
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
        window?.makeFirstResponder(search)
    }

    func windowDidResignKey(_ notification: Notification) {
        if window?.attachedSheet == nil { window?.orderOut(nil) }
    }

    private func build() {
        search.placeholderString = "搜索历史内容"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.controlSize = .large
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 66
        table.intercellSpacing = NSSize(width: 0, height: 5)
        table.style = .inset
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(copySelected)
        table.setAccessibilityLabel("剪贴板历史记录")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.heightAnchor.constraint(equalToConstant: 320).isActive = true
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
        let actions = UI.stack([
            ActionButton("复制", symbol: "doc.on.doc") { [weak self] in self?.commit(paste: false) },
            ActionButton("粘贴到原应用", symbol: "arrow.turn.down.left") { [weak self] in self?.commit(paste: true) },
            ActionButton("编辑", symbol: "pencil") { [weak self] in self?.editSelected() },
        ], axis: .horizontal, spacing: 8)
        let content = UI.stack([
            UI.label("剪贴板", size: 22, weight: .semibold), search, list, actions, status,
        ], spacing: 12)
        for view in [search, list] {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        window?.contentView = UI.glass(content, radius: 20, inset: 24)
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
        status.stringValue = "\(visibleEntries.count) 条记录  ·  ↑↓ 选择  ·  ↩ 复制  ·  ⌘↩ 粘贴  ·  ⌘E 编辑"
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
        icon.widthAnchor.constraint(equalToConstant: 38).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 38).isActive = true
        let title = UI.label(entry.title.isEmpty ? "空白文本" : entry.title, size: 13, weight: .medium)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        let subtitle = UI.label("\(entry.source) · \(entry.capturedAt.formatted(date: .omitted, time: .shortened))", size: 11, color: .secondaryLabelColor)
        let rowView = UI.stack([icon, UI.stack([title, subtitle], spacing: 5)], axis: .horizontal)
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
        case 3 where command: window?.makeFirstResponder(search)
        case 51 where command:
            if let entry = selectedEntry { store.remove(entry) }
        default: return false
        }
        return true
    }

    @objc private func copySelected() { commit(paste: false) }

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
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 360),
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
        scroll.borderType = .bezelBorder
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
        sheet.contentView = UI.glass(content)
        parent.beginSheet(sheet)
        sheet.makeFirstResponder(editor)
    }
}
