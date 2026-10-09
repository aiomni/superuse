import AppKit
import SuseCore

extension MonitorSeries {
    var accent: NSColor {
        switch self {
        case .cpu: .systemBlue
        case .memory, .swap: .systemPurple
        case .gpu: .systemGreen
        case .download, .upload: .systemTeal
        case .diskRead, .diskWrite, .availableSpace: .systemOrange
        case .cpuTemperature, .gpuTemperature, .battery: .systemPink
        }
    }
    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory, .swap: "memorychip"
        case .gpu: "square.3.layers.3d"
        case .download, .upload: "arrow.up.arrow.down"
        case .diskRead, .diskWrite, .availableSpace: "internaldrive"
        case .cpuTemperature, .gpuTemperature: "thermometer.medium"
        case .battery: "battery.100percent"
        }
    }
}

@MainActor
final class MonitorContentBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

@MainActor
final class MonitorSidebar: NSVisualEffectView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private var updating = false
    private let footer = UI.label("本地历史 · 最近 24 小时", size: 10, color: .tertiaryLabelColor)
    var onSelect: ((MonitorPage) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .sidebar; blendingMode = .behindWindow; state = .active
        let heading = UI.stack([UI.label("系统监控", size: 15, weight: .semibold),
                                UI.label("性能与历史", size: 11, color: .secondaryLabelColor)], spacing: 5)
        let column = NSTableColumn(identifier: .init("page")); table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 34; table.intercellSpacing = CGSize(width: 0, height: 4)
        table.style = .sourceList; table.backgroundColor = .clear
        table.dataSource = self; table.delegate = self
        table.setAccessibilityLabel("监控指标导航")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        MonitorScroller.install(in: scroll)
        for child in [heading, scroll, footer] { addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            heading.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 6),
            heading.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -20),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func setStorageMessage(_ message: String) { footer.stringValue = message; footer.toolTip = message }
    func select(_ page: MonitorPage) {
        updating = true
        if let index = MonitorPage.allCases.firstIndex(of: page) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        updating = false
    }
    func numberOfRows(in tableView: NSTableView) -> Int { MonitorPage.allCases.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let page = MonitorPage.allCases[row]
        let cell = NSTableCellView()
        let icon = NSBox()
        icon.boxType = .custom; icon.titlePosition = .noTitle
        icon.cornerRadius = 5; icon.borderWidth = 0
        icon.fillColor = page.accent
        let image = UI.symbol(page.symbol, size: 14, color: .white)
        icon.addSubview(image); image.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: page.title)
        label.font = .systemFont(ofSize: 13)
        cell.textField = label
        cell.addSubview(icon); cell.addSubview(label)
        icon.translatesAutoresizingMaskIntoConstraints = false; label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22), icon.heightAnchor.constraint(equalToConstant: 22),
            image.centerXAnchor.constraint(equalTo: icon.centerXAnchor), image.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6)
        ])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if !updating, MonitorPage.allCases.indices.contains(table.selectedRow) { onSelect?(MonitorPage.allCases[table.selectedRow]) }
    }
}

@MainActor
extension MonitorPage {
    var accent: NSColor {
        switch self {
        case .overview, .cpu: .systemBlue
        case .memory: .systemPurple
        case .gpu: .systemGreen
        case .network: .systemTeal
        case .disk: .systemOrange
        case .temperature: .systemPink
        }
    }
}
