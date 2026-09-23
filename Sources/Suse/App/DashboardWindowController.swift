import AppKit

@MainActor
final class DashboardWindowController: NSWindowController, NSToolbarDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let entries: [(feature: any FeatureModule, command: AppCommand)]
    private let hub: ShortcutHub
    private let openSettings: () -> Void
    private let settingsItemID = NSToolbarItem.Identifier("dashboard.settings")
    private let table = DashboardTableView()

    init(features: [any FeatureModule], hub: ShortcutHub, openSettings: @escaping () -> Void) {
        entries = features.flatMap { feature in feature.commands.map { (feature, $0) } }
        self.hub = hub
        self.openSettings = openSettings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 240),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(AppIdentity.name) 工具箱"
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "dashboard")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        build()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func show() {
        table.reloadData()
        if table.selectedRow < 0, !entries.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(table)
        NSApp.activate()
    }

    private func build() {
        table.addTableColumn(NSTableColumn(identifier: .init("command")))
        table.headerView = nil
        table.style = .inset
        table.rowHeight = 58
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(openSelectedCommand)
        table.onOpen = { [weak self] in self?.openSelectedCommand() }
        table.onDismiss = { [weak self] in self?.window?.orderOut(nil) }
        table.setAccessibilityLabel("工具箱功能列表")
        table.setAccessibilityIdentifier("dashboard-commands")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.heightAnchor.constraint(equalToConstant: CGFloat(min(max(entries.count, 1), 8)) * table.rowHeight + 16).isActive = true
        let hint = UI.padded(UI.label("↑↓ 选择   ↩ 打开   Esc 关闭", size: 11, color: .secondaryLabelColor), inset: 10)
        let content = UI.stack([scroll, hint], spacing: 0)
        scroll.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        hint.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        let background = ContentBackgroundView()
        background.addSubview(content)
        UI.pin(content, to: background, inset: 8)
        window?.contentView = background
        window?.setContentSize(CGSize(width: 440, height: background.fittingSize.height))
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        let cell = (tableView.makeView(withIdentifier: DashboardCommandCell.reuseIdentifier, owner: self) as? DashboardCommandCell)
            ?? DashboardCommandCell()
        cell.configure(command: entry.command, summary: entry.feature.summary,
                       shortcut: hub.shortcut(for: entry.command)?.displayValue)
        return cell
    }

    @objc private func openSelectedCommand() {
        guard entries.indices.contains(table.selectedRow) else { return }
        let command = entries[table.selectedRow].command
        window?.orderOut(nil)
        command.perform()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, settingsItemID] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [settingsItemID] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == settingsItemID else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "设置"
        item.toolTip = "设置与快捷键"
        item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置")
        item.target = self
        item.action = #selector(showSettings)
        return item
    }

    @objc private func showSettings() { openSettings() }
}

@MainActor
private final class DashboardTableView: NSTableView {
    var onOpen: (() -> Void)?
    var onDismiss: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            switch event.keyCode {
            case 36, 76: onOpen?(); return
            case 53: onDismiss?(); return
            default: break
            }
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class DashboardCommandCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("dashboard.command")
    private let icon = UI.symbol("square.grid.2x2", size: 20, color: .secondaryLabelColor)
    private let title = UI.label("", size: 13, weight: .medium)
    private let summary = UI.label("", size: 11, color: .secondaryLabelColor)
    private let shortcut = UI.label("", size: 11, color: .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        imageView = icon
        textField = title
        for label in [title, summary, shortcut] {
            label.usesSingleLineMode = true
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
        }
        shortcut.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        shortcut.setAccessibilityIdentifier("dashboard-shortcut")
        shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)
        shortcut.setContentHuggingPriority(.required, for: .horizontal)
        let labels = UI.stack([title, summary], spacing: 3)
        labels.setHuggingPriority(.defaultLow, for: .horizontal)
        let content = UI.stack([icon, labels, shortcut], axis: .horizontal, spacing: 12)
        content.distribution = .fill
        content.alignment = .centerY
        addSubview(content)
        UI.pin(content, to: self, inset: 8)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(command: AppCommand, summary: String, shortcut: String?) {
        icon.image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil)
        title.stringValue = command.title
        self.summary.stringValue = summary
        self.shortcut.stringValue = shortcut ?? "未设置"
        setAccessibilityIdentifier("dashboard-command-\(command.id)")
        setAccessibilityLabel("\(command.title)，\(summary)，\(shortcut ?? "未设置快捷键")")
        toolTip = "\(command.title)：\(summary)"
    }
}
