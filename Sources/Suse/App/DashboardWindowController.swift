import AppKit

@MainActor
final class DashboardWindowController: NSWindowController, NSToolbarDelegate {
    private let features: [any FeatureModule]
    private let hub: ShortcutHub
    private let openSettings: () -> Void
    private let settingsItemID = NSToolbarItem.Identifier("dashboard.settings")
    private var shortcutLabels: [(AppCommand, NSTextField)] = []

    init(features: [any FeatureModule], hub: ShortcutHub, openSettings: @escaping () -> Void) {
        self.features = features
        self.hub = hub
        self.openSettings = openSettings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 430),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = AppIdentity.name
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
        for (command, label) in shortcutLabels { label.stringValue = hub.shortcut(for: command)?.displayValue ?? "未设置快捷键" }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func build() {
        let header = UI.stack([
            UI.label("工具箱", size: 24, weight: .semibold),
            UI.label("截图、剪贴板与 Pin，一处唤起。", color: .secondaryLabelColor),
        ], spacing: 6)
        var content: [NSView] = [header]
        for feature in features {
            let heading = UI.stack([
                UI.symbol(feature.symbol, size: 26, color: .controlAccentColor),
                UI.stack([UI.label(feature.title, size: 17, weight: .semibold),
                          UI.label(feature.summary, size: 12, color: .secondaryLabelColor)], spacing: 5),
            ], axis: .horizontal, spacing: 14)
            let commands = feature.commands.map { command -> NSView in
                let shortcut = UI.label("", size: 12, color: .secondaryLabelColor)
                shortcut.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
                shortcutLabels.append((command, shortcut))
                let action = ActionButton(command.title, symbol: command.symbol, style: .glass) { [weak self] in
                    self?.window?.orderOut(nil)
                    command.perform()
                }
                return UI.row(shortcut, action)
            }
            let body = UI.stack([heading] + commands, spacing: 14)
            commands.forEach { $0.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
            content.append(UI.section(body, inset: 18))
        }
        content.append(UI.label("常驻菜单栏 · ⌃⌥Space 打开工具箱", size: 11, color: .secondaryLabelColor))
        let stack = UI.stack(content, spacing: 18)
        content.filter { $0 is NSBox }.forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let background = ContentBackgroundView()
        let controls = UI.glassContainer(stack)
        background.addSubview(controls)
        controls.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 24),
            controls.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -24),
            controls.topAnchor.constraint(equalTo: background.topAnchor, constant: 20),
            controls.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor, constant: -20),
        ])
        window?.contentView = background
        controls.layoutSubtreeIfNeeded()
        window?.setContentSize(CGSize(width: 600, height: max(430, controls.fittingSize.height + 40)))
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
