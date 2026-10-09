import AppKit
import SuseCore

@MainActor
final class SystemMonitorViewController: NSViewController {
    private var rows: [String: MonitorMetricRow] = [:]
    private let chart = SystemMonitorChart()
    private let cpuValue = UI.label("—", size: 25, weight: .semibold)
    private let cpuDetail = UI.label("正在采样…", size: 11, color: .secondaryLabelColor)
    private let memoryValue = UI.label("—", size: 25, weight: .semibold)
    private let memoryDetail = UI.label("正在采样…", size: 11, color: .secondaryLabelColor)
    private let memoryPressure = UI.label("", size: 11, color: .secondaryLabelColor)
    private let titleField = UI.label("系统监控", size: 14, weight: .medium)
    private var cpuCard: NSView?
    private var memoryCard: NSView?
    var onDetails: (() -> Void)?
    var onClose: (() -> Void)?
    var onSettings: (() -> Void)?

    override func loadView() {
        let details = ActionButton(icon: "打开监控窗口", symbol: "macwindow", style: .accessoryBar) { [weak self] in self?.onDetails?() }
        let activity = ActionButton(icon: "打开活动监视器", symbol: "waveform.path.ecg", style: .accessoryBar) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
        }
        activity.toolTip = "在系统活动监视器中查看各个进程"
        let settings = ActionButton(icon: "系统监控设置", symbol: "gearshape", style: .accessoryBar) { [weak self] in self?.onSettings?() }
        let close = ActionButton(icon: "关闭系统监控", symbol: "xmark", symbolColor: .systemRed, style: .accessoryBar) { [weak self] in self?.onClose?() }
        close.keyEquivalent = "\u{1b}"
        close.keyEquivalentModifierMask = []
        let actions = UI.glassContainer(UI.glassBar(UI.stack([details, activity, settings, close], axis: .horizontal, spacing: 6), radius: 12, inset: 4))
        actions.widthAnchor.constraint(equalToConstant: 186).isActive = true
        actions.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let heading = UI.row(UI.stack([UI.symbol("chart.xyaxis.line", size: 17),
                                      titleField], axis: .horizontal, spacing: 8), actions)
        cpuValue.font = .monospacedDigitSystemFont(ofSize: 25, weight: .semibold)
        memoryValue.font = cpuValue.font
        let cpu = summaryCard(title: "CPU", symbol: "cpu", value: cpuValue, detail: cpuDetail, accessory: chart)
        cpu.setAccessibilityIdentifier("monitor-cpu")
        cpuCard = cpu
        // Reserve the same space as the CPU chart, keeping both cards aligned.
        let memoryAccessory = UI.stack([memoryPressure], spacing: 0)
        memoryAccessory.heightAnchor.constraint(equalToConstant: 24).isActive = true
        memoryAccessory.alignment = .leading
        let memory = summaryCard(title: "内存", symbol: "memorychip", value: memoryValue, detail: memoryDetail, accessory: memoryAccessory)
        memory.setAccessibilityIdentifier("monitor-memory")
        memoryCard = memory
        let summaries = UI.stack([cpu, memory], axis: .horizontal, spacing: 10)
        summaries.alignment = .top
        summaries.distribution = .fillEqually
        cpu.widthAnchor.constraint(equalTo: memory.widthAnchor).isActive = true
        var metrics: [NSView] = [summaries]
        let list = UI.stack([], spacing: 0)
        for (key, title, symbol) in [
            ("gpu", "GPU", "square.3.layers.3d"), ("network", "网络", "network"),
            ("disk", "磁盘读写", "internaldrive"), ("space", "可用空间", "externaldrive"),
            ("battery", "电池", "battery.100percent"), ("temperature", "温度", "thermometer.medium"),
            ("thermal", "散热", "fan")
        ] {
            let row = MonitorMetricRow(title: title, symbol: symbol)
            row.setAccessibilityIdentifier("monitor-\(key)")
            rows[key] = row
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        metrics.append(list)
        let content = UI.stack(metrics, spacing: 12)
        metrics.forEach { $0.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        let document = FlippedView()
        document.addSubview(content)
        UI.pin(content, to: document)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let stack = UI.stack([heading, scroll], spacing: 12)
        for child in [heading, scroll] { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        // NSPopover supplies its native material. An opaque fill here hides that effect.
        view = NSView()
        view.addSubview(stack)
        UI.pin(stack, to: view, inset: 16)
        view.setAccessibilityIdentifier("system-monitor-panel")
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 440)
        render(SystemMetricsSnapshot(), history: [])
    }

    private func summaryCard(title: String, symbol: String, value: NSTextField, detail: NSTextField, accessory: NSView) -> NSView {
        detail.usesSingleLineMode = true
        detail.maximumNumberOfLines = 1
        detail.lineBreakMode = .byTruncatingTail
        let heading = UI.row(UI.label(title, size: 12, weight: .medium), UI.symbol(symbol, size: 14))
        let stack = UI.stack([heading, value, detail, accessory], spacing: 5)
        for child in [heading, detail, accessory] { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return UI.section(stack, inset: 10)
    }

    func render(_ snapshot: SystemMetricsSnapshot, history: [Double?]) {
        guard isViewLoaded else { return }
        chart.samples = history
        cpuValue.stringValue = SystemMetricFormat.percent(snapshot.cpu)
        cpuDetail.stringValue = snapshot.coreLoads.isEmpty ? "等待采样" : "\(snapshot.coreLoads.count) 个逻辑核心"
        cpuCard?.toolTip = snapshot.notes["cpu"] ?? "各核心：" + snapshot.coreLoads.map { SystemMetricFormat.percent($0) }.joined(separator: "  ")
        cpuCard?.setAccessibilityLabel("CPU 利用率")
        cpuCard?.setAccessibilityValue(cpuValue.stringValue + "，" + (cpuCard?.toolTip ?? ""))
        if let memory = snapshot.memory {
            let pressure = [1: "正常", 2: "偏高", 4: "很高"][memory.pressure ?? 0] ?? "不可用"
            memoryValue.stringValue = SystemMetricFormat.percent(memory.total > 0 ? Double(memory.used) / Double(memory.total) : nil)
            memoryDetail.stringValue = "\(SystemMetricFormat.bytes(memory.used)) / \(SystemMetricFormat.bytes(memory.total))"
            memoryPressure.stringValue = "内存压力 · \(pressure)"
            memoryPressure.textColor = memory.pressure == 4 ? .systemRed : memory.pressure == 2 ? .systemOrange : .secondaryLabelColor
            memoryCard?.toolTip = "\(memoryDetail.stringValue) · 压缩 \(SystemMetricFormat.bytes(memory.compressed)) · 交换 \(memory.swap.map(SystemMetricFormat.bytes) ?? "—")"
        } else {
            memoryValue.stringValue = "—"
            memoryDetail.stringValue = "等待采样"
            memoryPressure.stringValue = ""
            memoryCard?.toolTip = snapshot.notes["memory"] ?? "正在采样…"
        }
        memoryCard?.setAccessibilityLabel("内存利用率")
        memoryCard?.setAccessibilityValue("\(memoryValue.stringValue)，\(memoryDetail.stringValue)，\(memoryPressure.stringValue)，\(memoryCard?.toolTip ?? "")")
        set("gpu", value: SystemMetricFormat.percent(snapshot.gpu), detail: snapshot.notes["gpu"] ?? "最忙设备的利用率")
        set("network", value: snapshot.network.map { "↓ \(SystemMetricFormat.rate($0.incoming))   ↑ \(SystemMetricFormat.rate($0.outgoing))" } ?? "—",
            detail: snapshot.notes["network"] ?? "物理 Ethernet / Wi-Fi 接口合计")
        set("disk", value: snapshot.diskIO.map { "读 \(SystemMetricFormat.rate($0.incoming))   写 \(SystemMetricFormat.rate($0.outgoing))" } ?? "—",
            detail: snapshot.notes["disk"] ?? "所有可读取的物理磁盘合计")
        set("space", value: snapshot.diskSpace.map { SystemMetricFormat.bytes($0.available) } ?? "—",
            detail: snapshot.diskSpace.map { "启动磁盘容量 \(SystemMetricFormat.bytes($0.total))" } ?? snapshot.notes["space"] ?? "正在采样…")
        set("battery", value: snapshot.battery.map {
            SystemMetricFormat.percent($0.fraction) + " · " + ($0.charging ? "充电中" : $0.pluggedIn ? "已接电源" : "使用电池")
        } ?? "—", detail: snapshot.notes["battery"] ?? "内置电池电量")
        let cpuTemperature = snapshot.cpuTemperature.map { String(format: "CPU %.0f °C", $0) } ?? "CPU —"
        let gpuTemperature = snapshot.gpuTemperature.map { String(format: "GPU %.0f °C", $0) } ?? "GPU —"
        let fans = snapshot.fanRPM.isEmpty ? "未提供风扇读数" : "风扇 " + snapshot.fanRPM.map { String(format: "%.0f RPM", $0) }.joined(separator: " / ")
        set("temperature", value: "\(cpuTemperature)   \(gpuTemperature)",
            detail: (snapshot.notes["temperature"] ?? "传感器均值") + " · \(fans)")
        set("thermal", value: [0: "正常", 1: "温热", 2: "较高", 3: "严重"][snapshot.thermalState ?? -1] ?? "—",
            detail: "系统报告的热压力")
        if snapshot.sampledAt == nil { titleField.toolTip = "正在采样…" }
        else {
            let minutes = Int(snapshot.uptime / 60)
            titleField.toolTip = minutes < 60 ? "已运行 \(minutes) 分钟" :
                "已运行 \(minutes / 60) 小时 \(minutes % 60) 分钟"
        }
    }

    override func cancelOperation(_ sender: Any?) { onClose?() }

    private func set(_ key: String, value: String, detail: String) { rows[key]?.update(value: value, detail: detail) }
}

@MainActor
private final class MonitorMetricRow: NSView {
    private let value = UI.label("—", size: 12, weight: .medium)
    private let title: String

    init(title: String, symbol: String) {
        self.title = title
        super.init(frame: .zero)
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        value.usesSingleLineMode = true
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        let heading = UI.row(UI.stack([UI.symbol(symbol, size: 16), UI.label(title, size: 12)], axis: .horizontal, spacing: 8), value)
        addSubview(heading)
        UI.pin(heading, to: self, inset: 7)
        heightAnchor.constraint(equalToConstant: 32).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func update(value: String, detail: String) {
        self.value.stringValue = value
        toolTip = "\(title)：\(value)；\(detail)"
        setAccessibilityElement(true)
        setAccessibilityLabel(title)
        setAccessibilityValue("\(value)，\(detail)")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        CGRect(x: 7, y: 0, width: max(0, bounds.width - 14), height: 0.5).fill()
    }
}

@MainActor
private final class SystemMonitorChart: NSView {
    var samples: [Double?] = [] { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        setAccessibilityElement(true)
        setAccessibilityLabel("CPU 利用率趋势 · 最近 60 次采样")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 3)
        NSColor.separatorColor.setStroke()
        let grid = NSBezierPath()
        grid.move(to: CGPoint(x: rect.minX, y: rect.minY))
        grid.line(to: CGPoint(x: rect.maxX, y: rect.minY))
        grid.lineWidth = 0.5
        grid.stroke()
        let line = NSBezierPath()
        var connected = false
        for (index, sample) in samples.suffix(60).enumerated() {
            guard let sample, sample.isFinite else { connected = false; continue }
            let point = CGPoint(x: rect.minX + CGFloat(index) / 59 * rect.width,
                                y: rect.minY + CGFloat(min(1, max(0, sample))) * rect.height)
            if connected { line.line(to: point) } else { line.move(to: point) }
            connected = true
        }
        NSColor.controlAccentColor.setStroke()
        line.lineWidth = 1.5
        line.stroke()
    }
}
