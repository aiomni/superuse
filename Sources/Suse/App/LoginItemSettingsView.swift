import AppKit
import ServiceManagement

/// Access to the login-item registration owned by macOS.
@MainActor
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

@MainActor
final class LoginItemSettingsView: NSView {
    private let service: any LoginItemService
    private let toggle = NSSwitch()
    private let statusLabel = UI.label("", size: 11, color: .secondaryLabelColor)
    private let errorLabel = UI.label("", size: 11, color: .systemRed)
    private let systemSettings = ActionButton("打开登录项设置", symbol: "gearshape") {
        SMAppService.openSystemSettingsLoginItems()
    }

    init(service: any LoginItemService = SMAppService.mainApp) {
        self.service = service
        super.init(frame: .zero)
        toggle.target = self
        toggle.action = #selector(changeLoginItem)
        toggle.setAccessibilityLabel("开机启动")
        let row = UI.row(UI.stack([UI.label("开机启动"), statusLabel], spacing: 4), toggle)
        let content = UI.stack([row, systemSettings, errorLabel], spacing: 10)
        row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        errorLabel.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        addSubview(content)
        UI.pin(content, to: self)
        refresh()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { refresh() }
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        if let activatedWindow = notification.object as? NSWindow, activatedWindow === window { refresh() }
    }

    /// The system is the source of truth, including changes made in System Settings.
    @objc func refresh() {
        let status = service.status
        toggle.state = status == .enabled ? .on : .off
        toggle.isEnabled = status != .notFound
        systemSettings.isHidden = status != .requiresApproval
        errorLabel.isHidden = true
        switch status {
        case .notRegistered, .enabled:
            statusLabel.stringValue = "登录 Mac 后自动在菜单栏运行。"
        case .requiresApproval:
            statusLabel.stringValue = "尚未启用，请在系统登录项中允许 \(AppIdentity.name)。"
        case .notFound:
            statusLabel.stringValue = "无法读取启动状态，请重新打开应用后重试。"
        @unknown default:
            toggle.isEnabled = false
            statusLabel.stringValue = "暂时无法读取系统登录项状态。"
        }
    }

    @objc private func changeLoginItem() {
        let enabling = toggle.state == .on
        do {
            if enabling {
                // A denied item is already registered; only System Settings can approve it.
                if service.status == .notRegistered { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
            refresh()
        } catch {
            refresh()
            if !enabling || service.status != .requiresApproval {
                errorLabel.stringValue = "未能更新开机启动：\(error.localizedDescription)"
                errorLabel.isHidden = false
            }
        }
    }
}
