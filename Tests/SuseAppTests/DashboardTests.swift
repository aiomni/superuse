import AppKit
import Testing
import SuseCore
@testable import Suse

@Suite(.serialized)
@MainActor
struct DashboardTests {
    @Test func clickAndReturnInvokeTheSelectedCommandAcrossModules() throws {
        let fixture = DashboardFixture(commandCounts: [2, 1])
        defer { fixture.cleanUp() }
        let table = try fixture.table()
        #expect(table.numberOfRows == 3)

        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(table.sendAction(table.action, to: table.target))
        #expect(fixture.features[0].invocations == [1])
        #expect(fixture.features[1].invocations.isEmpty)

        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        table.keyDown(with: try key(36, characters: "\r"))
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table.keyDown(with: try key(76, characters: "\u{3}"))
        #expect(fixture.features[0].invocations == [1, 0])
        #expect(fixture.features[1].invocations == [0])
    }

    @Test func navigationKeysAndEmptySelectionDoNotInvokeCommands() throws {
        let fixture = DashboardFixture(commandCounts: [3])
        defer { fixture.cleanUp() }
        let table = try fixture.table()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table.keyDown(with: try key(125, characters: "\u{f701}"))
        #expect(table.selectedRow == 1)
        table.keyDown(with: try key(126, characters: "\u{f700}"))
        #expect(table.selectedRow == 0)
        table.keyDown(with: try key(53, characters: "\u{1b}"))
        #expect(fixture.features[0].invocations.isEmpty)

        table.deselectAll(nil)
        table.keyDown(with: try key(36, characters: "\r"))
        _ = table.sendAction(table.action, to: table.target)
        #expect(fixture.features[0].invocations.isEmpty)
    }

    @Test func rowsResolveCurrentShortcutOverridesAndDisabledCommands() throws {
        let fixture = DashboardFixture(commandCounts: [2])
        defer { fixture.cleanUp() }
        let table = try fixture.table()
        let command = fixture.features[0].commands[0]
        let initial = try rowLabel(0, in: table)
        #expect(initial.contains(try #require(command.defaultShortcut).displayValue))

        let shortcut = Shortcut(keyCode: 0, modifiers: [.shift, .command])
        fixture.settings.save(shortcut: shortcut, for: command.id)
        table.reloadData()
        let updated = try rowLabel(0, in: table)
        #expect(updated.contains(shortcut.displayValue))

        fixture.settings.setShortcutDisabled(true, for: command.id)
        table.reloadData()
        #expect(try rowLabel(0, in: table).contains("未设置快捷键"))
        #expect(try rowLabel(1, in: table).contains("未设置快捷键"))
    }

    @Test func largerCommandCollectionsScrollAndKeepEveryCommandAvailable() throws {
        let fixture = DashboardFixture(commandCounts: [12])
        defer { fixture.cleanUp() }
        let table = try fixture.table()
        let scroll = try #require(table.enclosingScrollView)
        #expect(table.numberOfRows == 12)
        #expect(scroll.frame.height < table.rowHeight * 9)
        table.selectRowIndexes(IndexSet(integer: 11), byExtendingSelection: false)
        table.scrollRowToVisible(11)
        #expect(table.visibleRect.intersects(table.rect(ofRow: 11)))
        table.keyDown(with: try key(36, characters: "\r"))
        #expect(fixture.features[0].invocations == [11])
    }

    private func key(_ code: UInt16, characters: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: 0, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private func rowLabel(_ row: Int, in table: NSTableView) throws -> String {
        let cell = try #require(table.delegate?.tableView?(table, viewFor: table.tableColumns[0], row: row))
        return try #require(cell.accessibilityLabel())
    }
}

@MainActor
private final class DashboardFixture {
    let suite = "app.suse.dashboard-tests.\(UUID().uuidString)"
    let settings: SettingsStore
    let features: [DashboardFeature]
    let controller: DashboardWindowController

    init(commandCounts: [Int]) {
        _ = NSApplication.shared
        settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        features = commandCounts.enumerated().map { DashboardFeature(id: "feature-\($0.offset)", count: $0.element) }
        controller = DashboardWindowController(features: features, hub: ShortcutHub(settings: settings), openSettings: {})
    }

    func table() throws -> NSTableView {
        let content = try #require(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        return try #require(descendants(content).first { $0 is NSTableView } as? NSTableView)
    }

    func cleanUp() {
        controller.close()
        settings.defaults.removePersistentDomain(forName: suite)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}

@MainActor
private final class DashboardFeature: FeatureModule {
    let id: String
    let count: Int
    let title = "测试功能"
    let symbol = "square.grid.2x2"
    let summary = "工具箱测试说明"
    var invocations: [Int] = []

    init(id: String, count: Int) { self.id = id; self.count = count }

    var commands: [AppCommand] {
        (0..<count).map { index in
            AppCommand(id: "\(id).\(index)", title: "测试操作 \(index + 1)", group: title, symbol: symbol,
                       defaultShortcut: index == 0 ? Shortcut(keyCode: 9, modifiers: [.control, .option]) : nil) { [weak self] in
                self?.invocations.append(index)
            }
        }
    }

    func start() {}
    func stop() {}
    func makeSettingsView() -> NSView { NSView() }
}
