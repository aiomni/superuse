import AppKit
import Testing
import SuseCore
@testable import Suse

@Suite(.serialized)
@MainActor
struct SystemMonitorTests {
    @Test func shutdownFlushesAcceptedMonitorWritesWhenViewsAreHidden() async throws {
        _ = NSApplication.shared
        let suite = "app.suse.monitor.flush.\(UUID().uuidString)"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = folder.appendingPathComponent("monitor.sqlite")
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        defer { settings.defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let module = SystemMonitorModule(settings: settings, sampler: SuspendedMetricsSampler(), showsUI: false, historyURL: url)
        #expect(module.recordsHistory)
        #expect(module.backgroundInterval == 5)
        let now = Date()
        for index in 0..<20 {
            var sample = SystemMetricsSnapshot(); sample.sampledAt = now.addingTimeInterval(Double(index - 20))
            sample.cpu = Double(index) / 100; sample.sampleInterval = 1
            module.accept(sample)
        }
        module.stop()
        await module.prepareForTermination()
        let disk = MonitorHistoryDisk(url: url)
        let records = try await disk.samples(from: now.addingTimeInterval(-30), to: now)
        #expect(records.count == 20)
        #expect(records.last?.cpu == 0.19)
        settings.defaults.set(false, forKey: "monitor.history")
        var disabled = SystemMetricsSnapshot(); disabled.sampledAt = now; disabled.cpu = 1
        module.accept(disabled)
        await module.prepareForTermination()
        #expect(try await disk.samples(from: now.addingTimeInterval(-30), to: now).count == 20)
    }

    @Test func menuCombinesMetricsAndUsesCompactStableWidths() {
        _ = NSApplication.shared
        let suite = "app.suse.monitor.\(UUID().uuidString)"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        defer { settings.defaults.removePersistentDomain(forName: suite) }
        let module = SystemMonitorModule(settings: settings, showsUI: false)
        var snapshot = SystemMetricsSnapshot()
        snapshot.cpu = 0.01
        module.accept(snapshot)
        let width = module.menuPresentation.width
        #expect(width < 75)
        snapshot.cpu = 1
        module.accept(snapshot)
        #expect(module.menuPresentation.width == width)
        settings.defaults.set(["cpu", "memory", "network", "network", "unknown"], forKey: "monitor.additionalMetrics")
        snapshot.memory = SystemMemory(used: 25, total: 100, compressed: 0, swap: nil, pressure: 1)
        snapshot.network = SystemIORate(incoming: 1024 * 1024, outgoing: 1024 * 10)
        module.accept(snapshot)
        #expect(module.menuMetrics == [.cpu, .memory, .network])
        #expect(module.menuPresentation.text.contains("内存 25% · ↓1.0M ↑10.0K"))
        #expect(module.menuPresentation.tooltip.contains("KiB/s"))
        settings.defaults.set("icon", forKey: "monitor.metric")
        #expect(module.menuPresentation.text.isEmpty)
    }

    @Test func menuMedianKeepsLivePanelValueAndMissingCurrentReadings() {
        _ = NSApplication.shared
        let suite = "app.suse.monitor.\(UUID().uuidString)"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        defer { settings.defaults.removePersistentDomain(forName: suite) }
        let module = SystemMonitorModule(settings: settings, showsUI: false)
        for cpu in [0.1, 0.2, 0.99] {
            var snapshot = SystemMetricsSnapshot()
            snapshot.cpu = cpu
            module.accept(snapshot)
        }
        #expect(module.menuPresentation.text == "CPU 20%")
        #expect(module.latest.cpu == 0.99)
        #expect(module.menuPresentation.tooltip.contains("范围 10%–99%"))
        settings.defaults.set(1, forKey: "monitor.samples")
        #expect(module.menuPresentation.text == "CPU 99%")
        settings.defaults.set(5, forKey: "monitor.samples")
        module.accept(SystemMetricsSnapshot())
        #expect(module.menuPresentation.text == "CPU —")
    }

    @Test func presentationAndIntervalChangesDoNotResetOrPublishCancelledReads() async throws {
        _ = NSApplication.shared
        let suite = "app.suse.monitor.\(UUID().uuidString)"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        defer { settings.defaults.removePersistentDomain(forName: suite) }
        settings.defaults.set(false, forKey: "monitor.history")
        let sampler = SuspendedMetricsSampler()
        let module = SystemMonitorModule(settings: settings, sampler: sampler, showsUI: false)
        module.start()
        defer { module.stop() }
        for _ in 0..<100 {
            if await sampler.waiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await sampler.finish()
        for _ in 0..<100 {
            if module.latest.cpu != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(module.menuPresentation.text == "CPU 50%")
        for _ in 0..<3 {
            module.refreshSampling()
            #expect(module.menuPresentation.text == "CPU 50%")
            for _ in 0..<100 {
                if await sampler.waiting { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await sampler.resets == 1)
            await sampler.finish()
            try await Task.sleep(for: .milliseconds(10))
            #expect(module.latest.cpu == 0.5)
        }
        settings.defaults.set(false, forKey: "monitor.menuBar")
        module.refreshSampling()
        try await Task.sleep(for: .milliseconds(20))
        settings.defaults.set(true, forKey: "monitor.menuBar")
        module.refreshSampling()
        for _ in 0..<100 {
            if await sampler.waiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await sampler.resets == 2)
        module.stop()
        await sampler.finish()
    }
    @Test func sensorDecoderRejectsMalformedValuesAndPreservesStoppedFans() {
        #expect(SystemTemperatureReader.decode(Data([0x32, 0x80]), type: "sp78") == 50.5)
        #expect(SystemTemperatureReader.decode(Data([0xff, 0x00]), type: "sp78") == -1)
        #expect(SystemTemperatureReader.decode(Data([0x1f, 0x40]), type: "fpe2") == 2_000)
        #expect(SystemTemperatureReader.decode(Data([0, 0]), type: "fpe2") == 0)
        #expect(SystemTemperatureReader.decode(Data([0, 0, 0x48, 0x42]), type: "flt ") == 50)
        #expect(SystemTemperatureReader.decode(Data([0, 0, 0x80, 0x7f]), type: "flt ") == nil)
        #expect(SystemTemperatureReader.decode(Data([0]), type: "sp78") == nil)
        #expect(SystemTemperatureReader.decode(Data([0, 0]), type: "unknown") == nil)
    }

    @Test func monitorUsesSharedCommandAndKeepsBoundedSessionHistory() throws {
        _ = NSApplication.shared
        let suite = "app.suse.monitor.\(UUID().uuidString)"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        defer { settings.defaults.removePersistentDomain(forName: suite) }
        let module = SystemMonitorModule(settings: settings, showsUI: false)
        let command = try #require(module.commands.first)
        #expect(command.id == "monitor.toggle")
        #expect(command.defaultShortcut == Shortcut(keyCode: 46))
        let hub = ShortcutHub(settings: settings)
        #expect(hub.shortcut(for: command) == command.defaultShortcut)
        settings.setShortcutDisabled(true, for: command.id)
        #expect(hub.shortcut(for: command) == nil)
        settings.defaults.set(-10, forKey: "monitor.interval")
        #expect(module.backgroundInterval == 5)
        for index in 0..<75 {
            var snapshot = SystemMetricsSnapshot()
            snapshot.cpu = Double(index) / 100
            module.accept(snapshot)
        }
        #expect(module.history.count == 60)
        #expect(module.history.first! == 0.15)
        module.stop()
        #expect(module.history.isEmpty)
        #expect(module.latest.cpu == nil)
    }

    @Test func cancelledSamplingDoesNotPublishLateResults() async throws {
        _ = NSApplication.shared
        let suite = "app.suse.monitor.\(UUID().uuidString)"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        defer { settings.defaults.removePersistentDomain(forName: suite) }
        settings.defaults.set(false, forKey: "monitor.history")
        let sampler = SuspendedMetricsSampler()
        let module = SystemMonitorModule(settings: settings, sampler: sampler, showsUI: false)
        module.start()
        for _ in 0..<100 {
            if await sampler.waiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await sampler.waiting)
        module.stop()
        await sampler.finish()
        try await Task.sleep(for: .milliseconds(30))
        #expect(module.latest.cpu == nil)
        #expect(module.history.isEmpty)
        await module.prepareForTermination()
        #expect(await sampler.resets >= 2)
    }

    @Test func hiddenMenuAndClosedPanelDoNotCollect() async throws {
        _ = NSApplication.shared
        let suite = "app.suse.monitor.\(UUID().uuidString)"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        defer { settings.defaults.removePersistentDomain(forName: suite) }
        settings.defaults.set(false, forKey: "monitor.menuBar")
        settings.defaults.set(false, forKey: "monitor.history")
        let sampler = SuspendedMetricsSampler()
        let module = SystemMonitorModule(settings: settings, sampler: sampler, showsUI: false)
        module.start()
        try await Task.sleep(for: .milliseconds(50))
        module.stop()
        #expect(await sampler.waiting == false)
        await module.prepareForTermination()
    }

    @Test func liveSystemReadsStayWithinTheirContractsAndResetBaselines() async throws {
        let sampler = SystemMetricsSampler()
        let first = await sampler.sample()
        #expect(first.cpu == nil)
        #expect(first.network == nil)
        #expect(first.diskIO == nil)
        #expect(first.sampledAt != nil)
        try await Task.sleep(for: .milliseconds(100))
        let second = await sampler.sample()
        let network = try #require(second.network)
        #expect(network.incoming.isFinite && network.incoming >= 0)
        #expect(network.outgoing.isFinite && network.outgoing >= 0)
        #expect(second.cpu.map { (0...1).contains($0) } ?? (second.notes["cpu"] != nil))
        #expect(second.memory.map { $0.used <= $0.total } ?? (second.notes["memory"] != nil))
        #expect(second.diskSpace.map { $0.available <= $0.total } ?? (second.notes["space"] != nil))
        #expect(second.gpu.map { (0...1).contains($0) } ?? (second.notes["gpu"] != nil))
        #expect(second.cpuTemperature.map { (1...130).contains($0) } ?? (second.notes["temperature"] != nil))
        #expect(second.fanRPM.allSatisfy { $0 >= 0 && $0 < 60_000 })
        await sampler.reset()
        let restarted = await sampler.sample()
        #expect(restarted.cpu == nil)
        #expect(restarted.network == nil)
        #expect(restarted.diskIO == nil)
        await sampler.reset()
    }
}

private actor SuspendedMetricsSampler: SystemMetricsSampling {
    private var continuation: CheckedContinuation<SystemMetricsSnapshot, Never>?
    private(set) var resets = 0
    var waiting: Bool { continuation != nil }

    func sample() async -> SystemMetricsSnapshot {
        await withCheckedContinuation { continuation = $0 }
    }

    func reset() { resets += 1 }

    func finish() {
        var snapshot = SystemMetricsSnapshot()
        snapshot.cpu = 0.5
        continuation?.resume(returning: snapshot)
        continuation = nil
    }
}
