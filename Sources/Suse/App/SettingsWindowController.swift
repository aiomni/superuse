import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let features: [any FeatureModule]
    private let hub: ShortcutHub
    private let sidebar = NSTableView()
    private let detail = ContentBackgroundView()
    private let split = NSSplitViewController()

    init(features: [any FeatureModule], hub: ShortcutHub) {
        self.features = features
        self.hub = hub
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 570),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "\(AppIdentity.name) 设置"
        window.toolbarStyle = .unifiedCompact
        window.toolbar = NSToolbar(identifier: "settings")
        window.minSize = NSSize(width: 740, height: 510)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Settings")
        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func show() { showWindow(nil); window?.center(); NSApp.activate() }
    func windowWillClose(_ notification: Notification) { window?.makeFirstResponder(nil); hub.resumeAfterRecording() }

    private func build() {
        sidebar.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section")))
        sidebar.headerView = nil
        sidebar.rowHeight = 38
        sidebar.style = .sourceList
        sidebar.backgroundColor = .clear
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.setAccessibilityLabel("设置分类")
        let scroll = NSScrollView()
        scroll.documentView = sidebar
        scroll.drawsBackground = false
        let navigation = NSViewController()
        navigation.view = NSView()
        navigation.view.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: navigation.view.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: navigation.view.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: navigation.view.safeAreaLayoutGuide.topAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: navigation.view.bottomAnchor, constant: -8),
        ])
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: navigation)
        sidebarItem.minimumThickness = 164
        sidebarItem.maximumThickness = 210
        sidebarItem.canCollapse = false
        let content = NSViewController()
        content.view = detail
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 500
        contentItem.automaticallyAdjustsSafeAreaInsets = true
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)
        window?.contentViewController = split
        split.splitView.setPosition(184, ofDividerAt: 0)
        sidebar.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { features.count + 2 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let names = [("通用", "slider.horizontal.3"), ("快捷键", "command")] + features.map { ($0.title, $0.symbol) }
        let cell = NSTableCellView()
        let image = NSImageView(image: NSImage(systemSymbolName: names[row].1, accessibilityDescription: nil) ?? NSImage())
        let label = NSTextField(labelWithString: names[row].0)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        cell.imageView = image
        cell.textField = label
        cell.addSubview(image)
        cell.addSubview(label)
        image.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 20), image.heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        window?.makeFirstResponder(sidebar)
        detail.subviews.forEach { $0.removeFromSuperview() }
        let page: NSView
        switch sidebar.selectedRow {
        case 0: page = generalPage()
        case 1: page = shortcutsPage()
        case 2... where sidebar.selectedRow - 2 < features.count:
            page = features[sidebar.selectedRow - 2].makeSettingsView()
        default: return
        }
        detail.addSubview(page)
        page.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: detail.safeAreaLayoutGuide.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: detail.safeAreaLayoutGuide.trailingAnchor),
            page.topAnchor.constraint(equalTo: detail.safeAreaLayoutGuide.topAnchor),
            page.bottomAnchor.constraint(equalTo: detail.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    private func generalPage() -> NSView {
        let recording = permissionRow("屏幕录制", subtitle: "用于截取屏幕、窗口和滚动内容。",
                                      symbol: "viewfinder", destination: "Privacy_ScreenCapture")
        let accessibility = permissionRow("辅助功能", subtitle: "用于将历史内容粘贴回原应用。",
                                          symbol: "hand.point.up.left", destination: "Privacy_Accessibility")
        return UI.settingsPage("通用", subtitle: "从菜单栏或快捷键访问你的工具。", controls: [
            UI.section(UI.stack([
                UI.label("常驻菜单栏", size: 14, weight: .semibold),
                UI.label("关闭窗口后，\(AppIdentity.name) 仍在运行。使用 ⌃⌥Space 打开工具箱，或从菜单栏选择功能。", color: .secondaryLabelColor),
            ], spacing: 8)),
            UI.groupedRows([recording, accessibility]),
            UI.label("仅复制剪贴板历史不需要辅助功能权限。", size: 12, color: .secondaryLabelColor),
        ])
    }

    private func permissionRow(_ title: String, subtitle: String, symbol: String, destination: String) -> NSView {
        let heading = UI.stack([UI.symbol(symbol, size: 20),
                                UI.stack([UI.label(title, weight: .medium),
                                          UI.label(subtitle, size: 12, color: .secondaryLabelColor)], spacing: 4)],
                               axis: .horizontal, spacing: 12)
        let action = ActionButton("打开设置") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(destination)")!)
        }
        return UI.row(heading, action)
    }

    private func shortcutsPage() -> NSView {
        var groups: [NSView] = []
        var groupNames: [String] = []
        for command in hub.commands where !groupNames.contains(command.group) { groupNames.append(command.group) }
        for name in groupNames {
            var rows: [NSView] = [UI.label(name, size: 12, weight: .semibold, color: .secondaryLabelColor)]
            for command in hub.commands where command.group == name {
                let recorder = ShortcutRecorder(command: command, hub: hub)
                recorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
                let heading = UI.stack([UI.symbol(command.symbol, size: 16), UI.label(command.title)], axis: .horizontal, spacing: 10)
                rows.append(UI.row(heading, recorder))
                if let error = hub.errors[command.id] { rows.append(UI.label(error, size: 11, color: .systemOrange)) }
            }
            let stack = UI.stack(rows, spacing: 12)
            rows.dropFirst().forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
            groups.append(UI.section(stack))
        }
        return UI.settingsPage("快捷键", subtitle: "所有功能的快捷键，在一处管理。", controls: groups + [
            UI.label("点击组合键重新录入；Delete 停用，Esc 取消。设置立即生效，并检查快捷键冲突。", size: 12, color: .secondaryLabelColor),
        ])
    }
}
