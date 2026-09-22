import AppKit
import SuseCore

@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private lazy var hub = ShortcutHub(settings: settings)
    private var features: [any FeatureModule] = []
    private var statusItem: NSStatusItem?
    private var dashboard: DashboardWindowController?
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
        statusItem?.button?.image = AppIcon.statusBarImage
        statusItem?.button?.toolTip = AppIdentity.name
        buildStatusMenu()
        if !AppLaunchContext.isLoginItem(NSAppleEventManager.shared().currentAppleEvent) {
            showDashboard()
        }
    }

    private func configureFeatures() {
        features = [ScreenshotModule(settings: settings), ClipboardModule(settings: settings)]
    }

    func applicationWillTerminate(_ notification: Notification) {
        features.forEach { $0.stop() }
        hub.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        features.forEach { $0.stop() }
        hub.stop()
        Task {
            for feature in features { await feature.prepareForTermination() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
        appMenu.addItem(withTitle: "退出 \(AppIdentity.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = appMenu
        menu.addItem(app)
        let file = NSMenuItem()
        file.title = "文件"
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.submenu = fileMenu
        menu.addItem(file)
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
        menu.addItem(withTitle: "退出 \(AppIdentity.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
    }

    @objc private func invokeMenu(_ sender: NSMenuItem) { menuActions[sender.tag]() }

    @objc private func showSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(features: features, hub: hub) }
        settingsWindow?.show()
    }

    private func showDashboard() {
        if dashboard == nil {
            dashboard = DashboardWindowController(features: features, hub: hub) { [weak self] in self?.showSettings() }
        }
        dashboard?.show()
    }
}
