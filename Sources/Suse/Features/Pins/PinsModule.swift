import AppKit
import SuseCore

@MainActor
final class PinsModule: NSObject, FeatureModule, PinPresenting, NSMenuDelegate {
    let id = "pins"
    let title = "悬浮内容"
    let symbol = "pin"
    let summary = "把图片和文字 Pin 到屏幕上，随时对照。"
    let store: PinStore
    private let pasteboard: NSPasteboard
    private let showsWindows: Bool
    private(set) var controllers: [UUID: PinWindowController] = [:]
    private var menuActions: [() -> Void] = []

    init(store: PinStore = PinStore(), pasteboard: NSPasteboard = .general, showsWindows: Bool = true) {
        self.store = store
        self.pasteboard = pasteboard
        self.showsWindows = showsWindows
        super.init()
        store.onChange = { [weak self] in self?.synchronizeWindows() }
    }

    var commands: [AppCommand] {
        [AppCommand(id: "pins.manage", title: "管理 Pin", group: title, symbol: symbol, defaultShortcut: nil) { [weak self] in
            guard let self else { return }
            makeMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }]
    }

    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        store.endSession()
    }

    func pin(_ request: PinRequest) throws { try store.insert(request) }
    func suspendForCapture() -> UUID { store.suspendForCapture() }
    func resumeAfterCapture(_ token: UUID) { store.resumeAfterCapture(token) }
    func closeClipboardPins(entryID: UUID?) { store.closeClipboardPins(entryID: entryID) }

    private func synchronizeWindows() {
        let ids = Set(store.items.map(\.id))
        for id in Array(controllers.keys) where !ids.contains(id) {
            let controller = controllers.removeValue(forKey: id)
            controller?.onClose = nil
            controller?.window?.close()
        }
        for (index, item) in store.items.enumerated() {
            if controllers[item.id] == nil {
                let preferred = item.preferredFrame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
                let screen = NSScreen.screens.first { $0.frame.contains(preferred) } ?? NSScreen.main ?? NSScreen.screens.first
                let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
                let offset = CGFloat(index % 6) * 20
                let anchor = item.preferredFrame.map { CGPoint(x: $0.minX, y: $0.maxY + PinGeometry.controlsHeight) }
                    ?? CGPoint(x: preferred.x + 20 + offset, y: preferred.y + 80 - offset)
                let controller = PinWindowController(item: item, visibleFrame: visibleFrame, anchor: anchor, pasteboard: pasteboard)
                let id = item.id
                controller.onClose = { [weak self] in
                    self?.controllers.removeValue(forKey: id)
                    self?.store.remove(id)
                }
                controller.onOpacity = { [weak self] in self?.store.setOpacity($0, for: id) }
                controller.onClickThrough = { [weak self] in self?.store.setClickThrough($0, for: id) }
                controller.validateTextChange = { [weak self] in try self?.store.validateTextUpdate($0, for: id) }
                controller.onTextChange = { [weak self] in try self?.store.updateText($0, for: id) }
                controllers[id] = controller
            }
            controllers[item.id]?.apply(item, visible: showsWindows && store.isVisible(item))
        }
    }

    @objc private func screensChanged() {
        let screens = NSScreen.screens.map(\.visibleFrame)
        controllers.values.forEach { $0.recover(on: screens) }
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "管理 Pin")
        menu.delegate = self
        menuNeedsUpdate(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        menuActions.removeAll()
        if store.items.isEmpty {
            let empty = NSMenuItem(title: "在截图或剪贴板中选择 Pin", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        if store.isCapturing {
            let status = NSMenuItem(title: "截图期间暂时隐藏", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }
        for (index, pin) in store.items.enumerated() {
            let id = pin.id
            let suffix = pin.isClickThrough ? " · 穿透" : pin.isHidden ? " · 已隐藏" : ""
            let item = add("\(index + 1). \(pin.title)\(suffix)", to: menu) { [weak self] in
                guard let self else { return }
                store.reveal(id)
                if showsWindows && !store.isCapturing { controllers[id]?.focus() }
            }
            item.state = store.isVisible(pin) ? .on : .off
            item.toolTip = "显示此 Pin 并恢复鼠标操作"
        }
        menu.addItem(.separator())
        add(store.allHidden ? "全部显示" : "全部隐藏", to: menu) { [weak self] in self?.store.toggleVisibility() }
        add("恢复全部操作", to: menu) { [weak self] in self?.store.restoreInteraction() }
        add("关闭全部 Pin", to: menu) { [weak self] in self?.store.removeAll() }
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

    func makeSettingsView() -> NSView {
        UI.settingsPage("悬浮内容", subtitle: "把临时参考放在手边。", controls: [
            UI.section(UI.stack([
                UI.label("截图与剪贴板共用 Pin", size: 16, weight: .semibold),
                UI.label("在截图预览或剪贴板历史中点击 Pin，也可以按 ⌘P。支持图片与纯文本，Pin 不会额外复制或保存内容。"),
            ])),
            UI.section(UI.stack([
                UI.label("操作浮窗", size: 16, weight: .semibold),
                UI.label("拖动图片或顶部移动窗口，拖动边缘调整大小。点击文字可直接编辑，支持粘贴、撤销和重做；修改仅保留在当前 Pin，复制时使用最新文字。更多菜单提供图片缩放、不透明度和鼠标穿透；开启穿透后，通过菜单栏「管理 Pin」恢复操作。⌘W 关闭当前 Pin。"),
            ])),
            UI.section(UI.stack([
                UI.label("仅保留当前会话", size: 16, weight: .semibold),
                UI.label("退出应用后清除全部 Pin，不写入磁盘。历史自动淘汰或编辑不会改变已 Pin 的内容；主动删除历史时会关闭相关 Pin。截图期间自动隐藏，结束或取消后恢复。"),
                UI.label("最多同时保留 16 个 Pin，内容内存预算为 256 MiB，单张图片最多 48 MP。", size: 12, color: .secondaryLabelColor),
            ])),
        ])
    }
}
