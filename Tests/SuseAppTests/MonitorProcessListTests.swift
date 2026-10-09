import AppKit
import Testing
import SuseCore
@testable import Suse

@Suite(.serialized)
@MainActor
struct MonitorProcessListTests {
    @Test func liveSelectionStaysStableButNeverLeaksIntoHistoricalSnapshots() throws {
        _ = NSApplication.shared
        let list = MonitorProcessList()
        func process(_ pid: Int32, _ cpu: Double) -> SystemProcessSample {
            .init(id: .init(pid: pid, startedAt: 1), name: "Synthetic \(pid)", cpu: cpu, memory: 100)
        }
        var snapshot = SystemMetricsSnapshot(); snapshot.processes = [process(1, 0.5), process(2, 0.1)]
        list.update(snapshot, historical: false)
        let table = try #require(descendants(list).compactMap { $0 as? NSTableView }.first)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        snapshot.processes = [process(2, 0.9), process(1, 0.1)]
        list.update(snapshot, historical: false)
        #expect(list.rows.map(\.id.pid) == [1, 2])
        #expect(table.selectedRow == 0)
        snapshot.processes = [process(2, 0.2)]
        list.update(snapshot, historical: false)
        #expect(list.rows.contains { $0.id.pid == 1 })
        list.update(snapshot, historical: true)
        #expect(list.rows.map(\.id.pid) == [2])
    }

    @Test func searchFiltersNameAndPIDAndMemorySortingUsesSavedValues() throws {
        _ = NSApplication.shared
        let list = MonitorProcessList()
        var snapshot = SystemMetricsSnapshot()
        snapshot.processes = [.init(id: .init(pid: 42, startedAt: 1), name: "Synthetic Editor", cpu: 0.9, memory: 10),
                              .init(id: .init(pid: 99, startedAt: 1), name: "Synthetic Worker", cpu: 0.1, memory: 100)]
        list.update(snapshot, historical: false)
        let search = try #require(descendants(list).compactMap { $0 as? NSSearchField }.first)
        search.stringValue = "worker"; list.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        #expect(list.rows.map(\.id.pid) == [99])
        search.stringValue = "42"; list.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        #expect(list.rows.map(\.id.pid) == [42])
        search.stringValue = ""; list.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        let sort = try #require(descendants(list).compactMap { $0 as? NSPopUpButton }.first)
        sort.selectItem(at: 1); sort.sendAction(sort.action, to: sort.target)
        #expect(list.rows.map(\.id.pid) == [99, 42])
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
}
