import AppKit
import SuseCore

@MainActor
enum MonitorPage: String, CaseIterable {
    case overview, cpu, memory, gpu, network, disk, temperature
    var title: String {
        switch self {
        case .overview: "总览"
        case .cpu: "CPU"
        case .memory: "内存"
        case .gpu: "GPU"
        case .network: "网络"
        case .disk: "磁盘"
        case .temperature: "温度与电池"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .gpu: "square.3.layers.3d"
        case .network: "arrow.up.arrow.down"
        case .disk: "internaldrive"
        case .temperature: "thermometer.medium"
        }
    }
}

@MainActor
final class MonitorDesktopWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private enum PlaybackState { case live, paused, history }

    private let settings: SettingsStore
    private let disk: MonitorHistoryDisk
    private let content = UI.stack([], spacing: 14)
    private let processList = MonitorProcessList()
    private let stateLabel = UI.label("实时更新", size: 12, color: .secondaryLabelColor)
    private let ranges = NSSegmentedControl(labels: ["5 分钟", "15 分钟", "1 小时", "6 小时", "24 小时"], trackingMode: .selectOne, target: nil, action: nil)
    private let styleChoice = NSPopUpButton()
    private let sidebar = MonitorSidebar()
    private var playbackButton: NSButton?
    private var returnToLiveButton: NSButton?
    private var pinButton: NSButton?
    private var documentMinimumHeight: NSLayoutConstraint?
    private let split = NSSplitViewController()
    private var cards: [(MonitorSeries, MonitorMetricCard)] = []
    private var loadingTask: Task<Void, Never>?
    private var processWindow: NSWindow?
    private var selectionTask: Task<Void, Never>?
    private var processTask: Task<Void, Never>?
    private var rangeTask: Task<Void, Never>?
    private var rangeRecords: [SystemMetricsSnapshot]?
    private var lastCompaction = Date.distantPast
    private(set) var selectedSnapshot: SystemMetricsSnapshot?
    private var detailCharts: [MonitorHistoryChart] = []
    private(set) var samples: [SystemMetricsSnapshot] = []
    private(set) var page: MonitorPage = .overview
    private(set) var timeRange = DateInterval(start: Date().addingTimeInterval(-900), duration: 900)
    private var playbackState = PlaybackState.live
    var live: Bool { playbackState == .live }
    private(set) var selectedTime: Date?
    private var latest = SystemMetricsSnapshot()
    private var expanded = false
    private var closing = false
    private var suppressFrameSave = true
    var onVisibilityChanged: (() -> Void)?
    var isCollecting: Bool { !closing && window?.isVisible == true && window?.isMiniaturized == false }
    private var pulse: Bool { settings.defaults.string(forKey: "monitor.chartStyle") == "pulse" }
    private let durations: [TimeInterval] = [300, 900, 3600, 21600, 86400]

    init(settings: SettingsStore, disk: MonitorHistoryDisk) {
        self.settings = settings; self.disk = disk
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 960, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "\(AppIdentity.name) · 系统监控"
        window.toolbarStyle = .unifiedCompact
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        window.minSize = CGSize(width: 800, height: 560)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        window.setContentSize(CGSize(width: 960, height: 680))
        if let saved = settings.defaults.string(forKey: "monitor.windowFrame") {
            let frame = NSRectFromString(saved)
            if frame.width >= 800, frame.height >= 560, let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) {
                let visible = screen.visibleFrame
                let width = min(frame.width, visible.width), height = min(frame.height, visible.height)
                window.setFrame(CGRect(x: min(max(visible.minX, frame.minX), visible.maxX - width),
                                       y: min(max(visible.minY, frame.minY), visible.maxY - height), width: width, height: height), display: false)
            } else { window.center() }
        } else { window.center() }
        window.level = settings.defaults.bool(forKey: "monitor.windowPinned") ? .floating : .normal
        suppressFrameSave = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    isolated deinit { loadingTask?.cancel(); selectionTask?.cancel(); processTask?.cancel(); rangeTask?.cancel() }

    private func build() {
        guard let window else { return }
        let toolbar = NSToolbar(identifier: "monitor.desktop.toolbar"); toolbar.delegate = self; toolbar.allowsUserCustomization = false; toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        ranges.selectedSegment = 1; ranges.target = self; ranges.action = #selector(rangeChanged)
        ranges.setAccessibilityLabel("监控历史时间范围")
        styleChoice.addItems(withTitles: ["流光曲线", "峰值脉冲"])
        styleChoice.selectItem(at: pulse ? 1 : 0); styleChoice.target = self; styleChoice.action = #selector(styleChanged)
        sidebar.onSelect = { [weak self] in self?.selectPage($0) }
        let document = FlippedView(); document.addSubview(content); UI.pin(content, to: document, inset: 18)
        let scroll = NSScrollView(); scroll.documentView = document; MonitorScroller.install(in: scroll)
        scroll.drawsBackground = false; scroll.contentView.drawsBackground = false
        document.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        documentMinimumHeight = document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor)
        let root = MonitorContentBackground(); root.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor),
                                     scroll.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor),
                                     scroll.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
                                     scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        root.setAccessibilityIdentifier("monitor-desktop-window")
        let navigation = NSViewController(); navigation.view = sidebar
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: navigation)
        sidebarItem.minimumThickness = 180; sidebarItem.maximumThickness = 220; sidebarItem.canCollapse = false
        let main = NSViewController(); main.view = root
        let mainItem = NSSplitViewItem(viewController: main)
        mainItem.minimumThickness = 560; mainItem.automaticallyAdjustsSafeAreaInsets = true
        split.addSplitViewItem(sidebarItem); split.addSplitViewItem(mainItem)
        window.contentViewController = split
        split.splitView.setPosition(196, ofDividerAt: 0)
        processList.onDetails = { [weak self] in self?.showProcess($0) }
        rebuild()
    }

    func open(latest: SystemMetricsSnapshot) {
        closing = false
        self.latest = latest
        NSApp.activate(); showWindow(nil); window?.makeKeyAndOrderFront(nil)
        onVisibilityChanged?()
        loadingTask?.cancel()
        loadingTask = Task { [weak self, disk] in
            do {
                let now = Date()
                let records = try await disk.chartSamples(from: now.addingTimeInterval(-MonitorHistory.retention), to: now, now: now)
                guard !Task.isCancelled, let self else { return }
                let incoming = samples
                var merged = Dictionary(records.compactMap { snapshot in snapshot.sampledAt.map { ($0, snapshot) } }, uniquingKeysWith: { _, new in new })
                for sample in incoming { if let time = sample.sampledAt { merged[time] = sample } }
                samples = merged.values.sorted { ($0.sampledAt ?? .distantPast) < ($1.sampledAt ?? .distantPast) }
                render()
            } catch is CancellationError { }
            catch { self?.sidebar.setStorageMessage("历史读取失败：\(error.localizedDescription)") }
        }
        render()
    }

    func accept(_ snapshot: SystemMetricsSnapshot) {
        latest = snapshot
        if let time = snapshot.sampledAt {
            if samples.last?.sampledAt == time { samples[samples.count - 1] = snapshot }
            else { samples.append(snapshot) }
            samples.removeAll { ($0.sampledAt ?? .distantPast) < time.addingTimeInterval(-MonitorHistory.retention) }
            if samples.count > 86401 { samples.removeFirst(samples.count - 86401) }
        }
        if let time = snapshot.sampledAt, time.timeIntervalSince(lastCompaction) >= MonitorHistory.bucketDuration {
            lastCompaction = time
            compactCache(at: time)
        }
        if live && isCollecting { render() }
    }

    private func compactCache(at now: Date) {
        let cutoff = floor(now.addingTimeInterval(-MonitorHistory.detailedRetention).timeIntervalSince1970 / MonitorHistory.bucketDuration) * MonitorHistory.bucketDuration
        var buckets: [Int: MonitorHistoryBucket] = [:]
        var recent: [SystemMetricsSnapshot] = []
        for sample in samples {
            guard let time = sample.sampledAt else { continue }
            if time.timeIntervalSince1970 >= cutoff { recent.append(sample); continue }
            let key = Int(floor(time.timeIntervalSince1970 / MonitorHistory.bucketDuration))
            var bucket = buckets[key] ?? MonitorHistoryBucket()
            bucket.append(sample); buckets[key] = bucket
        }
        samples = buckets.keys.sorted().map { buckets[$0]!.chartSnapshot } + recent
    }

    private func loadHistoricalRange() {
        rangeTask?.cancel(); rangeRecords = nil
        let range = timeRange
        rangeTask = Task { [weak self, disk] in
            do {
                let records = try await disk.chartSamples(from: range.start, to: range.end)
                guard !Task.isCancelled, let self, !live, timeRange == range else { return }
                var merged = Dictionary(records.compactMap { sample in sample.sampledAt.map { ($0, sample) } }, uniquingKeysWith: { _, new in new })
                for sample in samples where sample.historyAggregates.isEmpty {
                    if let time = sample.sampledAt, range.contains(time) { merged[time] = sample }
                }
                rangeRecords = merged.values.sorted { $0.sampledAt! < $1.sampledAt! }
                render()
            } catch is CancellationError { }
            catch { self?.storageFailed(error) }
        }
    }

    func stop() {
        loadingTask?.cancel(); loadingTask = nil; selectionTask?.cancel(); processTask?.cancel(); rangeTask?.cancel()
        window?.orderOut(nil); processWindow?.close(); processWindow = nil; detailCharts.removeAll(); samples.removeAll()
    }
    func storageFailed(_ error: Error) { sidebar.setStorageMessage("历史保存失败：\(error.localizedDescription)") }
    func windowWillClose(_ notification: Notification) { closing = true; loadingTask?.cancel(); onVisibilityChanged?() }
    func windowDidMiniaturize(_ notification: Notification) { onVisibilityChanged?() }
    func windowDidDeminiaturize(_ notification: Notification) { onVisibilityChanged?(); render() }
    func windowDidResize(_ notification: Notification) { saveFrame() }
    func windowDidMove(_ notification: Notification) { saveFrame() }
    private func saveFrame() { if !suppressFrameSave, let window { settings.defaults.set(NSStringFromRect(window.frame), forKey: "monitor.windowFrame") } }

    func selectPage(_ page: MonitorPage) { self.page = page; expanded = false; rebuild(); render() }
    private func rebuild() {
        documentMinimumHeight?.isActive = [.overview, .cpu, .memory].contains(page)
        content.arrangedSubviews.forEach { content.removeArrangedSubview($0); $0.removeFromSuperview() }
        cards.removeAll()
        let header = UI.row(UI.label(page == .overview ? "系统总览" : page.title, size: 17, weight: .semibold), stateLabel)
        header.heightAnchor.constraint(equalToConstant: 24).isActive = true
        content.addArrangedSubview(header); header.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        sidebar.select(page)
        let series: [MonitorSeries]
        switch page {
        case .overview: series = [.cpu, .memory, .gpu, .download, .diskRead, .cpuTemperature]
        case .cpu: series = [.cpu]
        case .memory: series = [.memory, .swap]
        case .gpu: series = [.gpu, .gpuTemperature]
        case .network: series = [.download]
        case .disk: series = [.diskRead, .availableSpace]
        case .temperature: series = [.cpuTemperature, .battery]
        }
        var row: NSStackView?
        for (index, key) in series.enumerated() {
            let card = MonitorMetricCard(title: cardTitle(key), compact: page == .overview)
            card.chart.onHover = { [weak self] time in self?.cards.forEach { $0.1.showHover(time) } }
            card.chart.onSelect = { [weak self] time in self?.selectTime(time) }
            card.chart.onZoom = { [weak self] range in self?.setHistoricalRange(range) }
            card.chart.onPan = { [weak self] offset in
                guard let self else { return }
                setHistoricalRange(DateInterval(start: timeRange.start.addingTimeInterval(offset), duration: timeRange.duration))
            }
            card.onExpand = { [weak self] in
                guard let self else { return }
                if page == .overview { selectPage(Self.page(for: key)) }
                else { expanded.toggle(); documentMinimumHeight?.isActive = !expanded && [.overview, .cpu, .memory].contains(page); processList.isHidden = expanded; cards.forEach { $0.1.isHidden = expanded && $0.0 != key; $0.1.setExpanded(expanded && $0.0 == key) } }
            }
            cards.append((key, card))
            if page == .overview {
                if index.isMultiple(of: 3) {
                    row = UI.stack([], axis: .horizontal, spacing: 12); row?.distribution = .fillEqually; row?.alignment = .top
                    content.addArrangedSubview(row!); row!.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
                }
                row?.addArrangedSubview(card)
            } else { content.addArrangedSubview(card); card.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        }
        if [.overview, .cpu, .memory].contains(page) { content.addArrangedSubview(processList); processList.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true; processList.isHidden = false }
    }

    func selectTime(_ time: Date) {
        selectionTask?.cancel()
        playbackState = .history; selectedTime = time
        selectedSnapshot = MonitorHistory.nearest(samples, to: time, tolerance: 0.05)
        render()
        if selectedSnapshot != nil { return }
        selectionTask = Task { [weak self, disk] in
            do {
                let snapshot = try await disk.snapshot(at: time, tolerance: 0.05)
                guard !Task.isCancelled, let self, selectedTime == time else { return }
                selectedSnapshot = snapshot
                render()
            } catch is CancellationError { }
            catch { self?.storageFailed(error) }
        }
    }
    func setHistoricalRange(_ proposed: DateInterval) {
        let now = Date(), duration = min(MonitorHistory.retention, max(5, proposed.duration))
        let end = min(now, max(now.addingTimeInterval(-MonitorHistory.retention + duration), proposed.end))
        timeRange = DateInterval(start: end.addingTimeInterval(-duration), duration: duration)
        playbackState = .history; selectedTime = nil; selectedSnapshot = nil; selectionTask?.cancel(); ranges.selectedSegment = -1; render(animated: true); loadHistoricalRange()
    }
    func returnToLive() {
        rangeTask?.cancel(); rangeRecords = nil; selectionTask?.cancel()
        selectedSnapshot = nil; selectedTime = nil; playbackState = .live
        render(animated: true)
    }
    @objc private func rangeChanged() {
        let index = ranges.selectedSegment; guard durations.indices.contains(index) else { return }
        timeRange = DateInterval(start: (live ? Date() : timeRange.end).addingTimeInterval(-durations[index]), duration: durations[index])
        selectionTask?.cancel(); selectedSnapshot = nil; selectedTime = nil; rangeRecords = nil; render(animated: true)
        if !live { loadHistoricalRange() }
    }
    @objc private func styleChanged() {
        settings.defaults.set(styleChoice.indexOfSelectedItem == 1 ? "pulse" : "flow", forKey: "monitor.chartStyle"); render()
    }

    private func render(animated: Bool = false) {
        updatePlaybackControls()
        if live { timeRange = DateInterval(start: Date().addingTimeInterval(-timeRange.duration), duration: timeRange.duration) }
        let plotting = rangeRecords ?? samples
        let displayed: SystemMetricsSnapshot
        if selectedTime != nil { displayed = selectedSnapshot ?? SystemMetricsSnapshot() }
        else { displayed = (live ? latest : plotting.last(where: { ($0.sampledAt ?? .distantFuture) <= timeRange.end })) ?? SystemMetricsSnapshot() }
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        switch playbackState {
        case .live: stateLabel.stringValue = "实时更新"
        case .paused: stateLabel.stringValue = "画面已暂停 · 后台继续采集"
        case .history: stateLabel.stringValue = selectedTime.map { "历史 · \(formatter.string(from: $0))" } ?? "查看历史 · 后台继续采集"
        }
        for (key, card) in cards {
            let keys = related(key)
            let scale = scale(key)
            let lines = keys.enumerated().map { index, series in
                MonitorHistoryChart.Line(series: series, title: title(series), color: index == 0 ? key.accent : (key == .cpuTemperature ? .systemOrange : .systemIndigo),
                                         points: MonitorHistory.points(plotting, series: series, from: timeRange.start, to: timeRange.end).map {
                    MonitorHistoryPoint(time: $0.time, value: $0.value.map { $0 / scale }, minimum: $0.minimum.map { $0 / scale },
                                        maximum: $0.maximum.map { $0 / scale }, peakTime: $0.peakTime, duration: $0.duration)
                })
            }
            let maximum = lines.flatMap(\.points).compactMap(\.maximum).max() ?? 1
            let ceiling: Double
            if [.cpu, .gpu, .battery].contains(key) { ceiling = 1 }
            else if [.memory, .swap].contains(key) { ceiling = max(1, Double(displayed.memory?.total ?? 0) / scale) }
            else if [.cpuTemperature, .gpuTemperature].contains(key) { ceiling = max(100, maximum * 1.05) }
            else { ceiling = max(1, maximum * 1.12) }
            let value = key.value(in: displayed)
            let formattedReading = value.map { format($0, series: key) } ?? "—"
            let reading = key == .download ? "↓ \(formattedReading)" : formattedReading
            card.update(title: cardTitle(key), reading: reading, detail: page == .overview ? summary(key, snapshot: displayed) : description(key, snapshot: displayed), lines: lines,
                        range: timeRange, ceiling: ceiling, unit: unit(key), pulse: pulse, animated: animated)
            card.chart.selectedTime = selectedTime
            card.showHover(nil)
        }
        processList.update(displayed, historical: !live)
    }

    private func showProcess(_ process: SystemProcessSample) {
        processTask?.cancel()
        let range = timeRange
        processTask = Task { [weak self, disk] in
            do {
                let raw = try await disk.samples(from: range.start, to: range.end)
                guard !Task.isCancelled, let self else { return }
                var merged = Dictionary(raw.compactMap { sample in sample.sampledAt.map { ($0, sample) } }, uniquingKeysWith: { _, new in new })
                for sample in samples where sample.historyAggregates.isEmpty {
                    if let time = sample.sampledAt, range.contains(time) { merged[time] = sample }
                }
                presentProcess(process, records: merged.values.sorted { $0.sampledAt! < $1.sampledAt! }, range: range)
            } catch is CancellationError { }
            catch { self?.storageFailed(error) }
        }
    }

    private func presentProcess(_ process: SystemProcessSample, records raw: [SystemMetricsSnapshot], range: DateInterval) {
        processWindow?.close()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(process.name) · PID \(process.id.pid)"
        window.isReleasedWhenClosed = false; window.minSize = CGSize(width: 480, height: 520)
        let stack = UI.stack([UI.label("仅显示进入 Top 列表时保存的读数；未记录时段留空。", size: 12, color: .secondaryLabelColor)], spacing: 10)
        let records = raw.map { sample -> SystemMetricsSnapshot in
            var result = SystemMetricsSnapshot(); result.sampledAt = sample.sampledAt; result.sampleInterval = sample.sampleInterval
            let found = sample.processes.first { $0.id == process.id }
            result.cpu = found?.cpu
            if let found { result.memory = .init(used: found.memory, total: found.memory, compressed: 0, swap: nil, pressure: nil) }
            return result
        }
        detailCharts.removeAll()
        for key in [MonitorSeries.cpu, .memory] {
            let card = MonitorMetricCard(title: title(key), compact: false)
            let points = MonitorHistory.points(records, series: key, from: range.start, to: range.end).map {
                MonitorHistoryPoint(time: $0.time, value: $0.value.map { $0 / scale(key) }, minimum: $0.minimum.map { $0 / scale(key) }, maximum: $0.maximum.map { $0 / scale(key) }, peakTime: $0.peakTime, duration: $0.duration)
            }
            card.update(title: title(key), reading: key == .cpu ? SystemMetricFormat.percent(process.cpu) : SystemMetricFormat.bytes(process.memory), detail: "采样时读数", lines: [.init(series: key, title: title(key), color: .systemBlue, points: points)], range: range,
                        ceiling: key == .cpu ? 1 : max(1, (points.compactMap(\.maximum).max() ?? 1) * 1.1), unit: unit(key), pulse: pulse, animated: false)
            card.chart.onHover = { [weak card] in card?.showHover($0) }
            stack.addArrangedSubview(card); card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            detailCharts.append(card.chart)
        }
        let document = FlippedView(); document.addSubview(stack); UI.pin(stack, to: document, inset: 16)
        let scroll = NSScrollView(); scroll.documentView = document; MonitorScroller.install(in: scroll)
        document.translatesAutoresizingMaskIntoConstraints = false; document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        window.contentView = scroll; window.center(); window.makeKeyAndOrderFront(nil); processWindow = window
    }

    private static func page(for key: MonitorSeries) -> MonitorPage {
        switch key {
        case .cpu: .cpu
        case .memory, .swap: .memory
        case .gpu: .gpu
        case .download, .upload: .network
        case .diskRead, .diskWrite, .availableSpace: .disk
        default: .temperature
        }
    }
    private func related(_ key: MonitorSeries) -> [MonitorSeries] {
        switch key {
        case .download: [.download, .upload]
        case .diskRead: [.diskRead, .diskWrite]
        case .cpuTemperature: [.cpuTemperature, .gpuTemperature]
        default: [key]
        }
    }
    private func title(_ key: MonitorSeries) -> String {
        switch key {
        case .cpu: "CPU"
        case .memory: "内存"
        case .swap: "交换空间"
        case .gpu: "GPU"
        case .download: "下载"
        case .upload: "上传"
        case .diskRead: "磁盘读取"
        case .diskWrite: "磁盘写入"
        case .availableSpace: "可用空间"
        case .cpuTemperature: "CPU 温度"
        case .gpuTemperature: "GPU 温度"
        case .battery: "电池"
        }
    }
    private func cardTitle(_ key: MonitorSeries) -> String { key == .download ? "网络" : title(key) }
    private func scale(_ key: MonitorSeries) -> Double {
        switch key {
        case .memory, .swap, .availableSpace: 1_073_741_824
        case .download, .upload, .diskRead, .diskWrite: 1_048_576
        default: 1
        }
    }
    private func unit(_ key: MonitorSeries) -> String {
        switch key {
        case .cpu, .gpu, .battery: "%"
        case .memory, .swap, .availableSpace: "GiB"
        case .download, .upload, .diskRead, .diskWrite: "MiB/s"
        default: "°C"
        }
    }
    private func format(_ value: Double, series: MonitorSeries) -> String {
        unit(series) == "%" ? SystemMetricFormat.percent(value) : String(format: "%.1f %@", value / scale(series), unit(series))
    }
    private func description(_ key: MonitorSeries, snapshot: SystemMetricsSnapshot) -> String {
        switch key {
        case .cpu:
            return snapshot.coreLoads.isEmpty ? snapshot.notes["cpu"] ?? "等待采样" : "\(snapshot.coreLoads.count) 个逻辑核心：" + snapshot.coreLoads.map { SystemMetricFormat.percent($0) }.joined(separator: " · ")
        case .memory:
            guard let memory = snapshot.memory else { return snapshot.notes["memory"] ?? "等待采样" }
            return "共 \(SystemMetricFormat.bytes(memory.total)) · 内存压力 \([1: "正常", 2: "偏高", 4: "很高"][memory.pressure ?? 0] ?? "不可用") · 压缩 \(SystemMetricFormat.bytes(memory.compressed))"
        case .download:
            let records = (rangeRecords ?? samples).filter { ($0.sampledAt ?? .distantPast) >= timeRange.start && ($0.sampledAt ?? .distantFuture) <= timeRange.end }
            let down = records.reduce(0.0) { $0 + ($1.historyAggregates[.download]?.weightedSum ?? (($1.network?.incoming ?? 0) * $1.sampleInterval)) }
            let up = records.reduce(0.0) { $0 + ($1.historyAggregates[.upload]?.weightedSum ?? (($1.network?.outgoing ?? 0) * $1.sampleInterval)) }
            return "区间流量 ↓ \(SystemMetricFormat.bytes(UInt64(max(0, down)))) ↑ \(SystemMetricFormat.bytes(UInt64(max(0, up))))"
        case .battery:
            return snapshot.battery.map { $0.charging ? "充电中" : $0.pluggedIn ? "已接电源" : "使用电池" } ?? snapshot.notes["battery"] ?? "不可用"
        case .cpuTemperature, .gpuTemperature:
            return "散热 \([0: "正常", 1: "温热", 2: "较高", 3: "严重"][snapshot.thermalState ?? -1] ?? "不可用") · 风扇 " + snapshot.fanRPM.map { String(format: "%.0f RPM", $0) }.joined(separator: " / ")
        default: return snapshot.notes[key == .gpu ? "gpu" : key == .diskRead ? "disk" : key == .availableSpace ? "space" : key.rawValue] ?? ""
        }
    }

    private func summary(_ key: MonitorSeries, snapshot: SystemMetricsSnapshot) -> String {
        switch key {
        case .cpu: return snapshot.coreLoads.isEmpty ? "等待采样" : "\(snapshot.coreLoads.count) 个逻辑核心"
        case .memory: return snapshot.memory.map { "共 \(SystemMetricFormat.bytes($0.total)) · 压力 \([1: "正常", 2: "偏高", 4: "很高"][$0.pressure ?? 0] ?? "—")" } ?? "不可用"
        case .gpu: return "图形处理器利用率"
        case .download: return "↑ \(snapshot.network.map { SystemMetricFormat.rate($0.outgoing) } ?? "—")"
        case .diskRead: return "写入 \(snapshot.diskIO.map { SystemMetricFormat.rate($0.outgoing) } ?? "—")"
        default: return snapshot.gpuTemperature.map { String(format: "GPU %.0f °C", $0) } ?? "温度传感器"
        }
    }
    private func togglePlayback() {
        switch playbackState {
        case .live: playbackState = .paused; render()
        case .paused: returnToLive()
        case .history: break
        }
    }
    private func updatePlaybackControls() {
        let title = playbackState == .paused ? "继续更新" : "暂停画面"
        playbackButton?.title = title
        playbackButton?.image = NSImage(systemSymbolName: playbackState == .paused ? "play.fill" : "pause", accessibilityDescription: title)
        playbackButton?.toolTip = title
        playbackButton?.setAccessibilityLabel(title)
        playbackButton?.isHidden = playbackState == .history
        returnToLiveButton?.isHidden = playbackState != .history
    }
    @objc private func resumeView() { returnToLive() }
    @objc private func togglePin() {
        guard let window else { return }
        let pinned = window.level != .floating; window.level = pinned ? .floating : .normal
        settings.defaults.set(pinned, forKey: "monitor.windowPinned")
        pinButton?.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: "置顶")
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("range"), .flexibleSpace, .init("style"), .init("actions")] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier.rawValue {
        case "range": item.label = "时间范围"; item.view = ranges
        case "style": item.label = "图表风格"; item.view = styleChoice
        case "actions":
            item.label = "监控操作"
            func control(_ title: String, symbol: String, action: @escaping () -> Void) -> NSButton {
                let button = ActionButton(title, symbol: symbol, action: action)
                button.imagePosition = .imageOnly; button.isBordered = false
                button.symbolConfiguration = .init(pointSize: 13, weight: .regular)
                button.toolTip = title
                button.widthAnchor.constraint(equalToConstant: 28).isActive = true
                button.heightAnchor.constraint(equalToConstant: 28).isActive = true
                return button
            }
            let playback = control("暂停画面", symbol: "pause") { [weak self] in self?.togglePlayback() }
            let resume = control("返回实时", symbol: "arrow.uturn.backward") { [weak self] in self?.resumeView() }
            let pin = control("置顶", symbol: settings.defaults.bool(forKey: "monitor.windowPinned") ? "pin.fill" : "pin") { [weak self] in self?.togglePin() }
            pinButton = pin
            playbackButton = playback; returnToLiveButton = resume
            updatePlaybackControls()
            let controls = UI.stack([playback, resume, pin], axis: .horizontal, spacing: 8)
            controls.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
            item.view = controls
        default: return nil
        }
        return item
    }
}
