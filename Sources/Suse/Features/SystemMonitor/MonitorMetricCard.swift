import AppKit
import SuseCore

@MainActor
final class MonitorMetricCard: NSView {
    let chart = MonitorHistoryChart()
    private let value = UI.label("—", size: 28, weight: .medium)
    private let statistics = UI.label("", size: 11, color: .secondaryLabelColor)
    private let detail = UI.label("", size: 12, color: .secondaryLabelColor)
    private let tooltip = UI.label("", size: 12, weight: .medium)
    private let titleField: NSTextField
    private let symbol = UI.symbol("cpu", size: 14)
    private let compact: Bool
    private let chartHeight: NSLayoutConstraint
    private var accent: NSColor = .systemBlue
    private let legend = NSStackView()
    private var activeSeries = Set<MonitorSeries>()
    private var allLines: [MonitorHistoryChart.Line] = []
    private var seriesButtons: [MonitorSeries: NSButton] = [:]
    var onExpand: (() -> Void)?

    init(title: String, compact: Bool) {
        self.compact = compact
        titleField = UI.label(title, size: 12, weight: .medium, color: .secondaryLabelColor)
        chartHeight = chart.heightAnchor.constraint(equalToConstant: compact ? 54 : 260)
        super.init(frame: .zero)
        chart.compact = compact
        chartHeight.isActive = true
        value.font = .monospacedDigitSystemFont(ofSize: compact ? 24 : 30, weight: .semibold)
        value.usesSingleLineMode = true
        value.lineBreakMode = .byClipping
        let expand = ActionButton(icon: compact ? "查看指标详情" : "展开或收起图表", symbol: compact ? "chevron.right" : "arrow.up.left.and.arrow.down.right", style: .standard) { [weak self] in self?.onExpand?() }
        expand.isBordered = false
        expand.contentTintColor = .tertiaryLabelColor
        expand.symbolConfiguration = .init(pointSize: 10, weight: .medium)
        let heading = UI.stack([symbol, titleField], axis: .horizontal, spacing: 6)
        let header = UI.row(heading, expand)
        header.heightAnchor.constraint(equalToConstant: 32).isActive = true
        legend.orientation = .horizontal; legend.spacing = 12; legend.alignment = .centerY
        let numberRow = compact ? UI.stack([value], axis: .horizontal, spacing: 0) : UI.row(value, statistics)
        numberRow.heightAnchor.constraint(equalToConstant: compact ? 29 : 36).isActive = true
        let stack = UI.stack([header, numberRow, detail, chart, legend, tooltip], spacing: compact ? 4 : 10)
        [header, numberRow, detail, chart, legend, tooltip].forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        addSubview(stack); UI.pin(stack, to: self, inset: compact ? 14 : 20)
        detail.font = .systemFont(ofSize: 11)
        detail.usesSingleLineMode = true; detail.lineBreakMode = .byTruncatingTail
        tooltip.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        tooltip.textColor = .secondaryLabelColor
        tooltip.isHidden = compact
        statistics.isHidden = compact
        legend.isHidden = compact
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        NSColor.alternatingContentBackgroundColors[1].setFill(); path.fill()
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            NSColor.separatorColor.setStroke(); path.lineWidth = 1; path.stroke()
        }
    }
    func setExpanded(_ expanded: Bool) { chartHeight.constant = expanded ? 440 : 260 }

    func update(title: String, reading: String, detail: String, lines: [MonitorHistoryChart.Line],
                range: DateInterval, ceiling: Double, unit: String, pulse: Bool, animated: Bool) {
        titleField.stringValue = title; value.stringValue = reading; self.detail.stringValue = detail
        self.detail.toolTip = detail
        accent = lines.first?.color ?? .systemBlue
        symbol.image = NSImage(systemSymbolName: lines.first?.series.symbol ?? "chart.xyaxis.line", accessibilityDescription: title)
        symbol.contentTintColor = accent
        allLines = lines
        if Set(seriesButtons.keys) != Set(lines.map(\.series)) {
            legend.arrangedSubviews.forEach { legend.removeArrangedSubview($0); $0.removeFromSuperview() }
            seriesButtons.removeAll(); activeSeries = Set(lines.map(\.series))
            for line in lines {
                let button = NSButton(title: line.title, target: self, action: #selector(toggleSeries(_:)))
                button.setButtonType(.toggle); button.isBordered = false
                button.font = .systemFont(ofSize: 11, weight: .medium)
                button.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
                button.symbolConfiguration = .init(pointSize: 6, weight: .regular)
                button.imagePosition = .imageLeading; button.contentTintColor = line.color
                button.state = .on; button.toolTip = "显示或隐藏 \(line.title)"; button.setAccessibilityLabel(line.title)
                seriesButtons[line.series] = button; legend.addArrangedSubview(button)
            }
        }
        chart.timeRange = range; chart.ceiling = ceiling; chart.unit = unit; chart.pulse = pulse
        chart.update(lines: lines.filter { activeSeries.contains($0.series) }, animated: animated)
        if let points = lines.first?.points, let maximum = points.compactMap(\.maximum).max() {
            let valid = points.filter { $0.value != nil }
            let weight = valid.reduce(0) { $0 + $1.duration }
            let mean = valid.reduce(0) { $0 + ($1.value ?? 0) * $1.duration } / max(0.001, weight)
            statistics.stringValue = "均值 \(formatted(mean, unit: unit)) · 峰值 \(formatted(maximum, unit: unit))"
        } else { statistics.stringValue = "暂无有效记录" }
        setAccessibilityLabel(title); setAccessibilityValue("\(reading)，\(detail)，\(statistics.stringValue)")
    }
    func showHover(_ time: Date?) {
        chart.hoverTime = time
        guard let time else { tooltip.stringValue = "框选放大 · ⌥拖动平移 · ⌘滚动缩放"; return }
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        let values = allLines.filter { activeSeries.contains($0.series) }.map { line -> String in
            let value = MonitorPlotGeometry.value(at: time, points: line.points)
            return "\(line.title) \(value.map { formatted($0, unit: chart.unit) } ?? "—")"
        }
        tooltip.stringValue = formatter.string(from: time) + " · " + values.joined(separator: "  ")
    }
    private func formatted(_ value: Double, unit: String) -> String {
        unit == "%" ? String(format: "%.0f%%", value * 100) : String(format: "%.1f %@", value, unit)
    }
    @objc private func toggleSeries(_ sender: NSButton) {
        guard let series = seriesButtons.first(where: { $0.value === sender })?.key else { return }
        if sender.state == .on { activeSeries.insert(series) } else { activeSeries.remove(series) }
        sender.alphaValue = sender.state == .on ? 1 : 0.35
        chart.update(lines: allLines.filter { activeSeries.contains($0.series) }, animated: false)
    }
}
