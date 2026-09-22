import AppKit
import SuseCore

@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private lazy var hub = ShortcutHub(settings: settings)
    private var features: [any FeatureModule] = []
    private var statusItem: NSStatusItem?
    private var dashboard: NSWindow?
    private var settingsWindow: SettingsWindowController?
    private var menuActions: [() -> Void] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureFeatures()
        let home = AppCommand(id: "app.home", title: "打开工具箱", group: "通用", symbol: "square.grid.2x2",
                              defaultShortcut: Shortcut(keyCode: 49)) { [weak self] in self?.showDashboard() }
        hub.install([home] + features.flatMap(\.commands))
        hub.onChange = { [weak self] in self?.buildStatusMenu() }
        features.forEach { $0.start() }
        buildApplicationMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Suse")
        buildStatusMenu()
        showDashboard()
    }

    private func configureFeatures() {
        features = [ScreenshotModule(settings: settings), ClipboardModule(settings: settings)]
    }

    func applicationWillTerminate(_ notification: Notification) {
        features.forEach { $0.stop() }
        hub.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return true
    }

    private func buildApplicationMenu() {
        let menu = NSMenu()
        let app = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Suse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = appMenu
        menu.addItem(app)
        let edit = NSMenuItem()
        edit.title = "编辑"
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", Selector(("undo:")), "z"),
                                     ("剪切", #selector(NSText.cut(_:)), "x"),
                                     ("复制", #selector(NSText.copy(_:)), "c"),
                                     ("粘贴", #selector(NSText.paste(_:)), "v"),
                                     ("全选", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        edit.submenu = editMenu
        menu.addItem(edit)
        NSApp.mainMenu = menu
    }

    private func buildStatusMenu() {
        let menu = NSMenu()
        menuActions.removeAll()
        var group = ""
        for command in hub.commands {
            if !group.isEmpty, group != command.group { menu.addItem(.separator()) }
            group = command.group
            let shortcut = hub.shortcut(for: command)?.displayValue ?? ""
            let item = NSMenuItem(title: command.title + (shortcut.isEmpty ? "" : "    \(shortcut)"),
                                  action: #selector(invokeMenu(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil)
            item.target = self
            item.tag = menuActions.count
            menuActions.append(command.perform)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "退出 Suse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
    }

    @objc private func invokeMenu(_ sender: NSMenuItem) { menuActions[sender.tag]() }

    @objc private func showSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(features: features, hub: hub) }
        settingsWindow?.show()
    }

    private func showDashboard() {
        if dashboard == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 510),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Suse"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            let background = NSVisualEffectView()
            background.material = .underWindowBackground
            background.blendingMode = .behindWindow
            var views: [NSView] = [UI.label("Suse", size: 32, weight: .bold),
                                   UI.label("轻一点，顺手一点。", size: 15, color: .secondaryLabelColor)]
            for feature in features {
                let actions = feature.commands.map { command in
                    ActionButton(command.title, symbol: command.symbol) { [weak window] in
                        window?.orderOut(nil)
                        command.perform()
                    }
                }
                views.append(UI.glass(UI.stack([
                    UI.label(feature.title, size: 18, weight: .semibold),
                    UI.label(feature.summary, color: .secondaryLabelColor),
                    UI.stack(actions, axis: .horizontal, spacing: 8),
                ])))
            }
            views.append(UI.stack([
                UI.label("常驻菜单栏 · ⌃⌥Space 随时打开", size: 12, color: .secondaryLabelColor),
                ActionButton("设置", symbol: "gearshape") { [weak self] in self?.showSettings() },
            ], axis: .horizontal, spacing: 24))
            let stack = UI.stack(views, spacing: 20)
            background.addSubview(stack)
            UI.pin(stack, to: background, inset: 32)
            for view in views where view is NSGlassEffectView {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            window.contentView = background
            window.center()
            dashboard = window
        }
        dashboard?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
