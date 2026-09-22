import AppKit
import SuseCore

@MainActor
final class ClipboardModule: FeatureModule {
    let id = "clipboard"
    let title = "剪贴板"
    let symbol = "clipboard"
    let summary = "找回刚才复制的文字和图片，接着使用。"
    private let settings: SettingsStore
    private let store: ClipboardStore
    private lazy var panel = ClipboardPanelController(store: store)

    init(settings: SettingsStore) {
        self.settings = settings
        self.store = ClipboardStore(settings: settings)
    }

    var commands: [AppCommand] {
        [AppCommand(id: "clipboard.history", title: "剪贴板历史", group: title, symbol: symbol,
                    defaultShortcut: Shortcut(keyCode: 9)) { [weak self] in self?.panel.toggle() }]
    }

    func start() { store.start() }
    func stop() { store.stop() }

    func makeSettingsView() -> NSView {
        let defaults = settings.defaults
        func toggle(_ title: String, key: String) -> NSView {
            ActionButton(checkbox: title, checked: defaults.bool(forKey: key)) { [weak self] enabled in
                defaults.set(enabled, forKey: key)
                self?.store.settingsChanged()
            }
        }
        let limit = NSSegmentedControl(labels: ["50 条", "100 条", "200 条"], trackingMode: .selectOne, target: self, action: #selector(limitChanged(_:)))
        limit.selectedSegment = [50, 100, 200].firstIndex(of: defaults.integer(forKey: "clipboard.limit")) ?? 1
        let exclusions = NSTextField(string: defaults.string(forKey: "clipboard.excludedApps") ?? "")
        exclusions.placeholderString = "com.example.passwordmanager, com.example.private"
        exclusions.target = self
        exclusions.action = #selector(exclusionsChanged(_:))
        exclusions.widthAnchor.constraint(equalToConstant: 450).isActive = true
        return UI.settingsPage("剪贴板历史", subtitle: "只在本机处理，随时暂停或清空。", controls: [
            toggle("记录剪贴板历史", key: "clipboard.enabled"),
            toggle("重启后保留历史（存储到本机磁盘）", key: "clipboard.persist"),
            toggle("忽略密码管理器等标记的敏感内容", key: "clipboard.ignoreSensitive"),
            UI.stack([UI.label("最多保留"), limit], axis: .horizontal),
            UI.stack([UI.label("排除应用 · Bundle ID，以逗号分隔，按回车保存", size: 12), exclusions], spacing: 6),
            ActionButton("清空全部历史", symbol: "trash") { [weak self] in self?.store.clear() },
            UI.label("↑↓ 选择，Return 复制，⌘Return 粘贴到唤起前的应用，⌘E 编辑，⌘Delete 删除。\n支持文本与图片；单条上限 8 MB，总计上限 32 MB。敏感标记由来源应用提供，无法识别所有秘密内容。", size: 12, color: .secondaryLabelColor),
        ])
    }

    @objc private func limitChanged(_ sender: NSSegmentedControl) {
        settings.defaults.set([50, 100, 200][sender.selectedSegment], forKey: "clipboard.limit")
        store.settingsChanged()
    }

    @objc private func exclusionsChanged(_ sender: NSTextField) {
        settings.defaults.set(sender.stringValue, forKey: "clipboard.excludedApps")
    }
}
