import AppKit
import SuseCore

@MainActor
final class MonitorProcessList: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let table = NSTableView()
    private let search = NSSearchField()
    private let sort = NSPopUpButton()
    private let heading = UI.label("当前高占用进程", size: 14, weight: .medium)
    private let status = UI.label("CPU 按整机总算力统计", size: 11, color: .secondaryLabelColor)
    private var source: [SystemProcessSample] = []
    private(set) var rows: [SystemProcessSample] = []
    private var selectedIdentity: SystemProcessIdentity?
    private var replacing = false
    var onDetails: ((SystemProcessSample) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        search.placeholderString = "搜索进程名称或 PID"
        search.delegate = self
        search.setAccessibilityLabel("搜索高占用进程")
        search.widthAnchor.constraint(equalToConstant: 160).isActive = true
        sort.addItems(withTitles: ["CPU 排序", "内存排序"])
        sort.target = self; sort.action = #selector(changeSort)
        sort.setAccessibilityLabel("进程排序")
        let details = ActionButton(icon: "查看进程趋势", symbol: "chart.xyaxis.line", style: .standard) { [weak self] in
            guard let self, rows.indices.contains(table.selectedRow) else { return }
            onDetails?(rows[table.selectedRow])
        }
        let tools = UI.stack([search, sort, details], axis: .horizontal, spacing: 8)
        let header = UI.row(heading, tools)
        header.heightAnchor.constraint(equalToConstant: 32).isActive = true
        for (id, title, width) in [("name", "进程", 210.0), ("pid", "PID", 70.0), ("cpu", "CPU", 90.0), ("memory", "内存", 110.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width
            column.minWidth = id == "name" ? 100 : 60
            table.addTableColumn(column)
        }
        table.rowHeight = 28
        table.style = .inset
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = false
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(openDetails)
        table.setAccessibilityLabel("CPU 和内存 Top 进程")
        table.toolTip = "CPU 按整机总算力统计 · 双击进程查看已记录的趋势"
        status.isHidden = true
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 162).isActive = true
        let preferredHeight = scroll.heightAnchor.constraint(equalToConstant: 162)
        preferredHeight.priority = .init(1); preferredHeight.isActive = true
        MonitorScroller.install(in: scroll)
        let stack = UI.stack([header, scroll, status], spacing: 8)
        [header, scroll, status].forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        addSubview(stack); UI.pin(stack, to: self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func update(_ snapshot: SystemMetricsSnapshot, historical: Bool) {
        if historical { selectedIdentity = nil }
        source = snapshot.processes
        status.isHidden = snapshot.notes["processes"] == nil
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        heading.stringValue = historical ? "\(snapshot.sampledAt.map(formatter.string) ?? "—") 当时高占用进程" : "当前高占用进程"
        status.stringValue = snapshot.notes["processes"] ?? "CPU 按整机总算力统计 · 双击进程查看已记录的趋势"
        reload(keepOrder: !historical && selectedIdentity != nil)
    }

    private func reload(keepOrder: Bool) {
        let query = search.stringValue
        var filtered = source.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || String($0.id.pid).contains(query) }
        filtered.sort {
            if sort.indexOfSelectedItem == 1 { return $0.memory == $1.memory ? $0.id.pid < $1.id.pid : $0.memory > $1.memory }
            return $0.cpu == $1.cpu ? $0.id.pid < $1.id.pid : ($0.cpu ?? -1) > ($1.cpu ?? -1)
        }
        if keepOrder {
            let identities = rows.map(\.id)
            var kept = identities.compactMap { id in filtered.first { $0.id == id } }
            if let selectedIdentity, !kept.contains(where: { $0.id == selectedIdentity }),
               let old = rows.first(where: { $0.id == selectedIdentity }), query.isEmpty {
                kept.append(old)
                status.isHidden = false
                status.stringValue = "选中进程暂未进入当前 Top；保留上次读数。点击空白取消选择。"
            }
            let seen = Set(kept.map(\.id))
            rows = kept + filtered.filter { !seen.contains($0.id) }
        } else { rows = filtered }
        replacing = true
        table.reloadData()
        if let selectedIdentity, let index = rows.firstIndex(where: { $0.id == selectedIdentity }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        replacing = false
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let sample = rows[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "pid": text = String(sample.id.pid)
        case "cpu": text = SystemMetricFormat.percent(sample.cpu)
        case "memory": text = SystemMetricFormat.bytes(sample.memory)
        default: text = sample.name
        }
        let field = UI.label(text, size: 12)
        field.usesSingleLineMode = true; field.lineBreakMode = .byTruncatingTail
        field.toolTip = text
        if tableColumn?.identifier.rawValue != "name" { field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular) }
        return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !replacing else { return }
        selectedIdentity = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
    }
    func controlTextDidChange(_ obj: Notification) { selectedIdentity = nil; reload(keepOrder: false) }
    @objc private func changeSort() { selectedIdentity = nil; reload(keepOrder: false) }
    @objc private func openDetails() { if rows.indices.contains(table.selectedRow) { onDetails?(rows[table.selectedRow]) } }
}
