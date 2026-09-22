import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let features: [any FeatureModule]
    private let hub: ShortcutHub
    private let sidebar = NSTableView()
    private let detail = NSView()

    init(features: [any FeatureModule], hub: ShortcutHub) {
        self.features = features
        self.hub = hub
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 570),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Suse 设置"
        window.minSize = NSSize(width: 740, height: 510)
        window.setFrameAutosaveName("Settings")
        super.init(window: window)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func show() { showWindow(nil); window?.center(); NSApp.activate() }

    private func build() {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        let material = NSVisualEffectView()
        material.material = .sidebar
        material.blendingMode = .behindWindow
        let scroll = NSScrollView()
        sidebar.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section")))
        sidebar.headerView = nil
        sidebar.rowHeight = 38
        sidebar.style = .sourceList
        sidebar.dataSource = self
        sidebar.delegate = self
        scroll.documentView = sidebar
        scroll.drawsBackground = false
        material.addSubview(scroll)
        UI.pin(scroll, to: material, inset: 10)
        split.addArrangedSubview(material)
        split.addArrangedSubview(detail)
        material.widthAnchor.constraint(greaterThanOrEqualToConstant: 165).isActive = true
        material.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
        window?.contentView = split
        split.setPosition(180, ofDividerAt: 0)
        sidebar.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { features.count + 2 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let names = [("通用", "slider.horizontal.3"), ("快捷键", "command")] + features.map { ($0.title, $0.symbol) }
        let image = NSImageView(image: NSImage(systemSymbolName: names[row].1, accessibilityDescription: nil)!)
        image.contentTintColor = .secondaryLabelColor
        image.widthAnchor.constraint(equalToConstant: 20).isActive = true
        return UI.stack([image, UI.label(names[row].0)], axis: .horizontal, spacing: 10)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        detail.subviews.forEach { $0.removeFromSuperview() }
        let page: NSView
        switch sidebar.selectedRow {
        case 0:
            page = UI.settingsPage("保持简单，随手可用", subtitle: "Suse · 原生 macOS 工具箱", controls: [
                UI.glass(UI.stack([
                    UI.label("各自独立，统一入口", size: 16, weight: .semibold),
                    UI.label("从菜单栏或快捷键访问工具。关闭窗口后，Suse 会继续在菜单栏运行。", color: .secondaryLabelColor),
                ])),
                ActionButton("屏幕录制权限", symbol: "rectangle.dashed.badge.record") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                },
                ActionButton("辅助功能权限", symbol: "hand.point.up.left") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                },
                UI.label("截图需要屏幕录制权限；将历史内容粘贴到其他应用需要辅助功能权限。仅复制历史内容不需要辅助功能权限。", color: .secondaryLabelColor),
                UI.label("macOS 26+ · AppKit · Liquid Glass", size: 11, color: .tertiaryLabelColor),
            ])
        case 1:
            var rows: [NSView] = []
            for command in hub.commands {
                let recorder = ShortcutRecorder(command: command, hub: hub)
                recorder.widthAnchor.constraint(equalToConstant: 150).isActive = true
                let label = UI.label(command.title)
                label.widthAnchor.constraint(equalToConstant: 170).isActive = true
                rows.append(UI.stack([label, recorder], axis: .horizontal))
                if let error = hub.errors[command.id] { rows.append(UI.label(error, size: 11, color: .systemOrange)) }
            }
            page = UI.settingsPage("快捷键中枢", subtitle: "所有功能的快捷键，在一处管理。", controls: [
                UI.stack(rows, spacing: 10),
                UI.label("点击按键录入；Delete 停用，Esc 取消。支持冲突检测，设置立即生效。", size: 12, color: .secondaryLabelColor),
            ])
        case 2... where sidebar.selectedRow - 2 < features.count:
            page = features[sidebar.selectedRow - 2].makeSettingsView()
        default: return
        }
        detail.addSubview(page)
        UI.pin(page, to: detail)
    }
}
