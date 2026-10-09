import AppKit
import SuseCore

protocol SystemMetricsSampling: Sendable {
    func sample() async -> SystemMetricsSnapshot
    func reset() async
}

extension SystemMetricsSampler: SystemMetricsSampling { }

@MainActor
final class SystemMonitorModule: NSObject, FeatureModule, NSPopoverDelegate, NSWindowDelegate {
    let id = "monitor"
    let title = "系统监控"
    let symbol = "chart.xyaxis.line"
    let summary = "查看 CPU、内存、网速、磁盘、电池与温度。"
    private let settings: SettingsStore
    private let sampler: any SystemMetricsSampling
    private let showsUI: Bool
    private let historyDisk: MonitorHistoryDisk?
    private var historyWrite: Task<Void, Never>?
    private(set) var desktop: MonitorDesktopWindowController?
    private let popover = NSPopover()
    let panel = SystemMonitorViewController()
    private var fallback: NSPanel?
    private var statusItem: NSStatusItem?
    private var samplingTask: Task<Void, Never>?
    private var sleeping = false
    private var started = false
    private var needsBaseline = true
    private var closingPanel = false
    private(set) var latest = SystemMetricsSnapshot()
    private(set) var history: [Double?] = []
    private var recentSamples: [SystemMetricsSnapshot] = []
    var onSettings: (() -> Void)?
    var onSample: ((SystemMetricsSnapshot) -> Void)?

    init(settings: SettingsStore, sampler: any SystemMetricsSampling = SystemMetricsSampler(), showsUI: Bool = true, historyURL: URL? = nil) {
        self.settings = settings
        self.sampler = sampler
        self.showsUI = showsUI
        let url = historyURL ?? (showsUI ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Suse/system-monitor.sqlite") : nil)
        historyDisk = url.map { MonitorHistoryDisk(url: $0) }
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = panel
        popover.delegate = self
        panel.onDetails = { [weak self] in self?.closePanel(); self?.openDesktop() }
        panel.onClose = { [weak self] in self?.closePanel() }
        panel.onSettings = { [weak self] in self?.closePanel(); self?.onSettings?() }
    }

    var commands: [AppCommand] {
        [AppCommand(id: "monitor.toggle", title: "显示系统监控", group: title, symbol: symbol,
                    defaultShortcut: Shortcut(keyCode: 46)) { [weak self] in self?.togglePanel() },
         AppCommand(id: "monitor.window", title: "打开监控窗口", group: title, symbol: "macwindow",
                    defaultShortcut: nil) { [weak self] in self?.openDesktop() }]
    }

    private var showsMenuItem: Bool {
        settings.defaults.object(forKey: "monitor.menuBar") as? Bool ?? true
    }

    var backgroundInterval: TimeInterval {
        let value = settings.defaults.double(forKey: "monitor.interval")
        return [3.0, 5.0, 10.0].contains(value) ? value : 5
    }

    var recordsHistory: Bool { settings.defaults.object(forKey: "monitor.history") as? Bool ?? true }
    private var hasCollectionDemand: Bool { showsMenuItem || isPanelShown || desktop?.isCollecting == true || recordsHistory }
    private var isPanelShown: Bool { popover.isShown || fallback?.isVisible == true }

    func start() {
        guard !started else { return }
        started = true
        if showsUI {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem?.button?.target = self
            statusItem?.button?.action = #selector(statusClicked)
            statusItem?.button?.font = MonitorMenuPresentation.font
            statusItem?.button?.setAccessibilityLabel("\(AppIdentity.name) 系统监控")
            statusItem?.isVisible = showsMenuItem
            updateStatusItem()
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        refreshSampling(resetBaselines: true)
    }

    func stop() {
        started = false
        samplingTask?.cancel()
        samplingTask = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        closePanel()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        desktop?.stop()
        latest = SystemMetricsSnapshot()
        history.removeAll()
        recentSamples.removeAll()
        panel.render(latest, history: history)
    }

    func prepareForTermination() async {
        await samplingTask?.value
        await historyWrite?.value
        await sampler.reset()
    }

    func refreshSampling(resetBaselines: Bool = false, clearHistory: Bool = false) {
        if resetBaselines { needsBaseline = true }
        if !hasCollectionDemand {
            needsBaseline = true
            recentSamples.removeAll()
        }
        let previousTask = samplingTask
        samplingTask?.cancel()
        samplingTask = nil
        if clearHistory {
            latest = SystemMetricsSnapshot()
            history.removeAll()
            recentSamples.removeAll()
        }
        updateStatusItem()
        panel.render(latest, history: history)
        guard started, !sleeping else { samplingTask = previousTask; return }
        let sampler = self.sampler
        samplingTask = Task { [weak self] in
            // Finish an in-flight read before changing its baseline or taking another sample.
            await previousTask?.value
            guard !Task.isCancelled else { return }
            while !Task.isCancelled {
                let shouldSample = self.map { $0.hasCollectionDemand } ?? false
                if shouldSample {
                    if self?.needsBaseline == true {
                        await sampler.reset()
                        guard !Task.isCancelled else { break }
                        self?.recentSamples.removeAll()
                        self?.needsBaseline = false
                    }
                    let snapshot = await sampler.sample()
                    guard !Task.isCancelled, let self else { break }
                    accept(snapshot)
                } else {
                    self?.needsBaseline = true
                    self?.recentSamples.removeAll()
                }
                let interval = self.map { $0.isPanelShown || $0.desktop?.isCollecting == true ? 1.0 : $0.backgroundInterval } ?? 3.0
                do { try await Task.sleep(for: .seconds(interval)) }
                catch { break }
            }
            // Reset only on startup or after a real pause; presentation changes keep counters.
        }
    }

    func accept(_ snapshot: SystemMetricsSnapshot) {
        latest = snapshot
        desktop?.accept(snapshot)
        if recordsHistory, let historyDisk, snapshot.sampledAt != nil {
            let previous = historyWrite
            historyWrite = Task { [weak self] in
                await previous?.value
                do { try await historyDisk.append(snapshot) }
                catch { self?.desktop?.storageFailed(error) }
            }
        }
        recentSamples.append(snapshot)
        if recentSamples.count > 10 { recentSamples.removeFirst(recentSamples.count - 10) }
        history.append(snapshot.cpu)
        if history.count > 60 { history.removeFirst(history.count - 60) }
        updateStatusItem()
        // Hidden views defer their work; they are refreshed before the next presentation.
        if isPanelShown { panel.render(snapshot, history: history) }
        onSample?(snapshot)
    }

    func openDesktop() {
        guard showsUI, let historyDisk else { return }
        if desktop == nil {
            let controller = MonitorDesktopWindowController(settings: settings, disk: historyDisk)
            controller.onVisibilityChanged = { [weak self] in if self?.started == true { self?.refreshSampling() } }
            desktop = controller
        }
        desktop?.open(latest: latest)
    }

    @objc private func statusClicked() { togglePanel() }

    func togglePanel() {
        guard showsUI else { return }
        if isPanelShown { closePanel(); return }
        let screen = statusItem?.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let height = min(440, max(300, (screen?.visibleFrame.height ?? 700) - 40))
        popover.contentSize = CGSize(width: 400, height: height)
        panel.loadViewIfNeeded()
        panel.render(latest, history: history)
        statusItem?.isVisible = true
        NSApp.activate()
        if let button = statusItem?.button, let window = button.window,
           window.screen != nil, window.frame.width > 0 {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        } else {
            // A crowded menu bar (including the notch) can hide the item's anchor.
            // The hot key still opens a native panel at the top-right of this display.
            let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 400, height: height),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.delegate = self
            window.title = "系统监控"
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.contentView = panel.view
            let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
            window.setFrameTopLeftPoint(CGPoint(x: visible.maxX - 412, y: visible.maxY - 12))
            fallback = window
            window.makeKeyAndOrderFront(nil)
        }
        refreshSampling()
    }

    func closePanel() {
        closingPanel = true
        popover.performClose(nil)
        closingPanel = false
        fallback?.orderOut(nil)
        // Detach before handing the view back to the popover.
        fallback?.contentView = nil
        fallback = nil
        statusItem?.isVisible = showsMenuItem
        if started { refreshSampling() }
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem?.isVisible = showsMenuItem
        if started && !closingPanel { refreshSampling() }
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === fallback else { return }
        closePanel()
    }

    @objc private func willSleep() {
        sleeping = true
        refreshSampling(resetBaselines: true, clearHistory: true)
    }

    @objc private func didWake() {
        sleeping = false
        refreshSampling(resetBaselines: true, clearHistory: true)
    }

    var menuMetrics: [MonitorMenuMetric] {
        let primary = settings.defaults.string(forKey: "monitor.metric") ?? "cpu"
        if primary == "icon" { return [] }
        let first = MonitorMenuMetric(rawValue: primary) ?? .cpu
        let additional = settings.defaults.stringArray(forKey: "monitor.additionalMetrics") ?? []
        return [first] + MonitorMenuMetric.allCases.filter { $0 != first && additional.contains($0.rawValue) }
    }

    var menuSampleCount: Int {
        let value = settings.defaults.integer(forKey: "monitor.samples")
        return [1, 5, 10].contains(value) ? value : 5
    }

    var menuPresentation: MonitorMenuPresentation {
        MonitorMenuPresentation(metrics: menuMetrics, latest: latest, samples: recentSamples, sampleCount: menuSampleCount)
    }

    private func updateStatusItem() {
        let presentation = menuPresentation
        statusItem?.length = menuMetrics.isEmpty ? NSStatusItem.squareLength : presentation.width
        statusItem?.button?.title = presentation.text
        statusItem?.button?.image = menuMetrics.isEmpty ? NSImage(systemSymbolName: symbol, accessibilityDescription: title) : nil
        statusItem?.button?.toolTip = presentation.tooltip
        statusItem?.button?.setAccessibilityValue(presentation.text.isEmpty ? title : presentation.text)
    }

    func makeSettingsView() -> NSView {
        let primaryKeys = MonitorMenuMetric.allCases.map(\.rawValue) + ["icon"]
        let metric = MonitorChoice(titles: MonitorMenuMetric.allCases.map(\.title) + ["仅图标"],
                                   selected: primaryKeys.firstIndex(of: settings.defaults.string(forKey: "monitor.metric") ?? "cpu") ?? 0) { [weak self] index in
            self?.settings.defaults.set(primaryKeys[index], forKey: "monitor.metric")
            self?.updateStatusItem()
        }
        metric.setAccessibilityLabel("菜单栏主指标")
        let sampling = MonitorChoice(titles: ["实时读数", "最近 5 次中位数", "最近 10 次中位数"],
                                     selected: [1, 5, 10].firstIndex(of: menuSampleCount) ?? 1) { [weak self] index in
            self?.settings.defaults.set([1, 5, 10][index], forKey: "monitor.samples")
            self?.updateStatusItem()
        }
        sampling.setAccessibilityLabel("菜单栏采样统计")
        let additions = MonitorMenuMetric.allCases.map { item in
            UI.toggleRow(item.title, isOn: settings.defaults.stringArray(forKey: "monitor.additionalMetrics")?.contains(item.rawValue) == true) { [weak self] on in
                guard let self else { return }
                var selected = settings.defaults.stringArray(forKey: "monitor.additionalMetrics") ?? []
                selected.removeAll { $0 == item.rawValue }
                if on { selected.append(item.rawValue) }
                settings.defaults.set(selected, forKey: "monitor.additionalMetrics")
                updateStatusItem()
            }
        }
        let interval = MonitorChoice(titles: ["3 秒", "5 秒", "10 秒"], selected: [3.0, 5.0, 10.0].firstIndex(of: backgroundInterval) ?? 0) { [weak self] index in
            self?.settings.defaults.set([3.0, 5.0, 10.0][index], forKey: "monitor.interval")
            self?.refreshSampling()
        }
        interval.setAccessibilityLabel("后台采样间隔")
        return UI.settingsPage(title, subtitle: "在菜单栏查看此 Mac 的运行状态。", controls: [
            UI.groupedRows([
                UI.toggleRow("在菜单栏显示", subtitle: "隐藏后仍可通过工具箱和快捷键打开。", isOn: showsMenuItem) { [weak self] on in
                    guard let self else { return }
                    settings.defaults.set(on, forKey: "monitor.menuBar")
                    statusItem?.isVisible = on || isPanelShown
                    refreshSampling()
                },
                UI.row(UI.label("菜单栏主指标"), metric),
                UI.row(UI.label("菜单栏读数"), sampling),
                UI.row(UI.label("后台采样间隔"), interval),
                UI.toggleRow("保存最近 24 小时监控历史", subtitle: "仅保存在本机；包括 CPU、内存 Top 进程。关闭后停止新增记录，已有记录按保留期限清理。", isOn: recordsHistory) { [weak self] on in
                    self?.settings.defaults.set(on, forKey: "monitor.history")
                    self?.refreshSampling()
                },
            ]),
            UI.section(UI.stack([
                UI.label("菜单栏附加指标", size: 16, weight: .semibold),
                UI.label("可组合多个指标；主指标不会重复显示。选择「仅图标」时不显示文字。", size: 12, color: .secondaryLabelColor),
                UI.groupedRows(additions),
            ])),
            UI.section(UI.stack([
                UI.label("快速查看", size: 16, weight: .semibold),
                UI.label("点击监控指标或使用快捷键展开；再次按快捷键或 Esc 关闭。在「快捷键」中修改「显示系统监控」，默认 ⌃⌥M。展开时每秒采样，温度每 3 秒、容量每 30 秒更新。"),
                UI.label("桌面窗口提供 24 小时趋势、图表缩放和历史 Top 进程关联。可为「打开监控窗口」单独绑定快捷键。历史记录开启时后台持续采样；关闭历史且隐藏所有监控界面时暂停。监控不发送网络请求。", size: 12, color: .secondaryLabelColor),
            ])),
            UI.section(UI.stack([
                UI.label("读数说明", size: 16, weight: .semibold),
                UI.label("菜单栏默认显示最近 5 次采样的中位数。悬停可查看实时读数、有效次数和波动范围；面板始终显示实时读数。样本不足时按已有读数计算，失败读数不当作零。", size: 12, color: .secondaryLabelColor),
                UI.label("网络统计物理 Ethernet / Wi-Fi 接口，磁盘吞吐量合计可读取的物理设备。GPU 使用驱动统计，温度与风扇使用只读 SMC 接口；部分硬件可能不提供读数。散热状态来自系统热压力。"),
                UI.label("温度显示采样传感器均值。内存已用为物理容量减去空闲和文件缓存；可能与活动监视器的分类略有不同。", size: 12, color: .secondaryLabelColor),
            ])),
        ])
    }
}

@MainActor
private final class MonitorChoice: NSPopUpButton {
    private let changed: (Int) -> Void

    init(titles: [String], selected: Int, changed: @escaping (Int) -> Void) {
        self.changed = changed
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: titles)
        selectItem(at: selected)
        target = self
        action = #selector(invoke)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc private func invoke() { changed(indexOfSelectedItem) }
}
