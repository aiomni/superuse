import AppKit
import Foundation
import Testing
import SuseCore
@testable import Suse

@Suite(.serialized)
@MainActor
struct MonitorDesktopTests {
    @Test func onePlaybackButtonResumesPausedUpdatesAndHistoryShowsOnlyReturnToLive() throws {
        _ = NSApplication.shared
        let suite = "app.suse.monitor.playback.\(UUID().uuidString)"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        defer { settings.defaults.removePersistentDomain(forName: suite) }
        let disk = MonitorHistoryDisk(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("monitor.sqlite"))
        let controller = MonitorDesktopWindowController(settings: settings, disk: disk)
        defer { controller.stop() }
        let toolbar = try #require(controller.window?.toolbar)
        let controls = try #require(toolbar.items.first { $0.itemIdentifier.rawValue == "actions" }?.view)
        let buttons = descendants(controls).compactMap { $0 as? NSButton }
        let playback = try #require(buttons.first { $0.title == "暂停画面" })
        let returnToLive = try #require(buttons.first { $0.title == "返回实时" })
        #expect(!playback.isHidden && returnToLive.isHidden)
        #expect(buttons.filter { !$0.isHidden }.count == 2)

        var first = SystemMetricsSnapshot(); first.sampledAt = Date().addingTimeInterval(-30); first.cpu = 0.9
        controller.accept(first)
        playback.performClick(nil)
        let root = try #require(controller.window?.contentView)
        let cpuCard = try #require(descendants(root).compactMap { $0 as? MonitorMetricCard }.first)
        func showsCPU(_ value: String) -> Bool { descendants(cpuCard).compactMap { $0 as? NSTextField }.contains { $0.stringValue == value } }
        #expect(!controller.live)
        #expect(playback.title == "继续更新")
        #expect(playback.toolTip == "继续更新")
        #expect(!playback.isHidden && returnToLive.isHidden)
        #expect(showsCPU("90%"))
        let pausedRange = controller.timeRange
        var next = first; next.sampledAt = Date(); next.cpu = 0.1
        controller.accept(next)
        #expect(controller.samples.count == 2)
        #expect(controller.timeRange == pausedRange)
        #expect(showsCPU("90%"))
        playback.performClick(nil)
        #expect(controller.live)
        #expect(playback.title == "暂停画面")
        #expect(returnToLive.isHidden)
        #expect(showsCPU("10%"))

        controller.selectTime(try #require(first.sampledAt))
        #expect(!controller.live && playback.isHidden && !returnToLive.isHidden)
        #expect(buttons.filter { !$0.isHidden }.count == 2)
        #expect(controller.selectedSnapshot?.cpu == first.cpu)
        returnToLive.performClick(nil)
        #expect(controller.live && controller.selectedTime == nil && controller.selectedSnapshot == nil)
        #expect(!playback.isHidden && returnToLive.isHidden)

        controller.setHistoricalRange(DateInterval(start: Date().addingTimeInterval(-600), duration: 300))
        #expect(playback.isHidden && !returnToLive.isHidden)
        returnToLive.performClick(nil)
        #expect(controller.live && controller.timeRange.duration == 300)
        #expect(!playback.isHidden && returnToLive.isHidden)
    }

    @Test func tallOverviewUsesRemainingSpaceForProcessesAndKeepsOneHistoryCaption() throws {
        _ = NSApplication.shared
        let suite = "app.suse.monitor.resizing.\(UUID().uuidString)"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        defer { settings.defaults.removePersistentDomain(forName: suite) }
        let disk = MonitorHistoryDisk(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("monitor.sqlite"))
        let controller = MonitorDesktopWindowController(settings: settings, disk: disk)
        defer { controller.stop() }
        let window = try #require(controller.window)
        window.setContentSize(CGSize(width: 960, height: 900))
        controller.selectPage(.overview)
        let root = try #require(window.contentView); root.layoutSubtreeIfNeeded()
        let list = try #require(descendants(root).compactMap { $0 as? MonitorProcessList }.first)
        let scroll = try #require(descendants(list).compactMap { $0 as? NSScrollView }.first)
        #expect(scroll.bounds.height > 250)
        #expect(scroll.verticalScroller is MonitorScroller)
        let history = descendants(root).compactMap { $0 as? NSTextField }.filter { $0.stringValue == "本地历史 · 最近 24 小时" }
        #expect(history.count == 1)
    }

    @Test func selectingOlderAggregatedPeakLoadsItsActualProcessSnapshot() async throws {
        _ = NSApplication.shared
        let suite = "app.suse.monitor.peak.\(UUID().uuidString)"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        defer { settings.defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let disk = MonitorHistoryDisk(url: folder.appendingPathComponent("monitor.sqlite"))
        let controller = MonitorDesktopWindowController(settings: settings, disk: disk)
        defer { controller.stop() }
        let now = Date(), peakTime = now.addingTimeInterval(-1800)
        var peak = SystemMetricsSnapshot(); peak.sampledAt = peakTime; peak.cpu = 0.95; peak.sampleInterval = 5
        peak.processes = [.init(id: .init(pid: 42, startedAt: 1), name: "Exited synthetic worker", cpu: 0.8, memory: 100)]
        try await disk.append(peak, now: now)
        var ordinary = peak; ordinary.sampledAt = peakTime.addingTimeInterval(5); ordinary.cpu = 0.1; ordinary.processes = []
        try await disk.append(ordinary, now: now)
        var bucket = MonitorHistoryBucket(); bucket.append(peak); bucket.append(ordinary)
        controller.accept(bucket.chartSnapshot)
        controller.selectTime(peakTime)
        for _ in 0..<100 {
            if controller.selectedSnapshot != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(controller.selectedSnapshot?.cpu == 0.95)
        #expect(controller.selectedSnapshot?.processes == peak.processes)
        controller.returnToLive()
        #expect(controller.selectedSnapshot == nil)
    }

    @Test func historicalSelectionKeepsFrameFixedWhileCollectionContinues() throws {
        _ = NSApplication.shared
        let suite = "app.suse.monitor.desktop.\(UUID().uuidString)"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        defer { settings.defaults.removePersistentDomain(forName: suite) }
        let disk = MonitorHistoryDisk(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("monitor.sqlite"))
        let controller = MonitorDesktopWindowController(settings: settings, disk: disk)
        defer { controller.stop() }
        let time = Date().addingTimeInterval(-30)
        var first = SystemMetricsSnapshot(); first.sampledAt = time; first.cpu = 0.9; first.sampleInterval = 5
        controller.accept(first)
        controller.selectPage(.cpu)
        controller.selectTime(time)
        #expect(!controller.live)
        #expect(controller.selectedTime == time)
        let frozen = controller.timeRange
        var next = first; next.sampledAt = time.addingTimeInterval(5); next.cpu = 0.1
        controller.accept(next)
        #expect(controller.samples.count == 2)
        #expect(controller.timeRange == frozen)
        #expect(controller.selectedTime == time)
        controller.returnToLive()
        #expect(controller.live)
        #expect(controller.selectedTime == nil)
        controller.setHistoricalRange(DateInterval(start: Date().addingTimeInterval(-600), duration: 300))
        #expect(!controller.live)
        #expect(controller.timeRange.duration == 300)
    }

    @Test func desktopLayoutsCoverEveryMetricAndSupportedAppearance() throws {
        _ = NSApplication.shared
        let suite = "app.suse.monitor.layout.\(UUID().uuidString)"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        defer { settings.defaults.removePersistentDomain(forName: suite) }
        let disk = MonitorHistoryDisk(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("monitor.sqlite"))
        let controller = MonitorDesktopWindowController(settings: settings, disk: disk)
        defer { controller.stop() }
        let window = try #require(controller.window)
        let now = Date()
        for index in 0..<120 {
            var sample = SystemMetricsSnapshot()
            sample.sampledAt = now.addingTimeInterval(Double(index - 120) * 5); sample.sampleInterval = 5
            sample.cpu = 0.2 + 0.65 * exp(-pow(Double(index - 65) / 8, 2)); sample.coreLoads = Array(repeating: sample.cpu, count: 8)
            sample.memory = .init(used: 8_000_000_000, total: 16_000_000_000, compressed: 400_000_000, swap: 0, pressure: 1)
            sample.gpu = 0.25; sample.network = .init(incoming: 3_000_000, outgoing: 200_000)
            sample.diskIO = .init(incoming: 4_000_000, outgoing: 100_000); sample.diskSpace = .init(total: 500_000_000_000, available: 200_000_000_000)
            sample.cpuTemperature = 55; sample.gpuTemperature = 60; sample.thermalState = 0
            sample.battery = .init(fraction: 0.7, charging: false, pluggedIn: false)
            sample.processes = [.init(id: .init(pid: 42, startedAt: 1), name: "Synthetic worker", cpu: 0.1, memory: 400_000_000)]
            controller.accept(sample)
        }
        let appearances: [NSAppearance.Name] = [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]
        for appearance in appearances {
            window.appearance = NSAppearance(named: appearance)
            for size in [CGSize(width: 960, height: 680), CGSize(width: 800, height: 560)] {
                window.setContentSize(size)
                for page in MonitorPage.allCases {
                    controller.selectPage(page)
                    let root = try #require(window.contentView)
                    root.layoutSubtreeIfNeeded()
                    #expect(!root.hasAmbiguousLayout)
                    let charts = descendants(root).compactMap { $0 as? MonitorHistoryChart }
                    #expect(!charts.isEmpty)
                    #expect(charts.allSatisfy { $0.bounds.width > 100 && $0.bounds.height > 0 })
                    if page == .overview || page == .network {
                        let network = try #require(descendants(root).compactMap { $0 as? MonitorMetricCard }.first { $0.chart.lines.first?.series == .download })
                        let fields = descendants(network).compactMap { $0 as? NSTextField }
                        #expect(fields.contains { $0.stringValue == "网络" })
                        let download = try #require(fields.first { $0.stringValue.hasPrefix("↓ ") })
                        let width = (download.stringValue as NSString).size(withAttributes: [.font: try #require(download.font)]).width
                        #expect(width <= download.bounds.width)
                        #expect(network.chart.lines.map(\.title) == ["下载", "上传"])
                        #expect(network.chart.lines.map(\.series) == [.download, .upload])
                    }
                    if let folder = ProcessInfo.processInfo.environment["SUSE_UI_PREVIEW_DIRECTORY"], size.width == 960 {
                        let url = URL(fileURLWithPath: folder).appendingPathComponent("monitor-desktop-\(page.rawValue)-\(appearance.rawValue).png")
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if let image = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                            root.cacheDisplay(in: root.bounds, to: image)
                            try image.representation(using: .png, properties: [:])?.write(to: url)
                        }
                    }
                }
            }
        }
    }

    @Test func windowCommandHasIndependentConfigurableShortcut() throws {
        _ = NSApplication.shared
        let suite = "app.suse.monitor.command.\(UUID().uuidString)"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        defer { settings.defaults.removePersistentDomain(forName: suite) }
        let module = SystemMonitorModule(settings: settings, showsUI: false)
        let command = try #require(module.commands.first { $0.id == "monitor.window" })
        #expect(command.defaultShortcut == nil)
        let custom = Shortcut(keyCode: 46, modifiers: [.control, .option, .shift])
        settings.save(shortcut: custom, for: command.id)
        let hub = ShortcutHub(settings: settings)
        #expect(hub.shortcut(for: command) == custom)
        #expect(module.commands.first?.defaultShortcut == Shortcut(keyCode: 46))
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
}
