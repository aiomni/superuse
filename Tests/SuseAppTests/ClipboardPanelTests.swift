import AppKit
import Testing
import SuseCore
@testable import Suse

@Suite(.serialized)
@MainActor
struct ClipboardPanelTests {
    @Test func contextMenuPinsWithoutCopyingAndSearchDisablesDragging() async throws {
        _ = NSApplication.shared
        let suite = "app.suse.clipboard-panel.\(UUID())"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        let pasteboard = NSPasteboard.withUniqueName()
        let url = FileManager.default.temporaryDirectory.appending(path: "\(suite)/history.sqlite")
        defer {
            settings.defaults.removePersistentDomain(forName: suite)
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let store = ClipboardStore(settings: settings, pasteboard: pasteboard, persistenceURL: url,
            source: { ClipboardSource(name: "Fixture", bundleIdentifier: "com.example.fixture") })
        for text in ["other", "needle"] {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            store.checkForChanges()
        }
        let panel = ClipboardPanelController(store: store)
        await panel.waitForReload()
        let window = try #require(panel.window)
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        let table = try #require(descendants(content).first { $0 is NSTableView } as? NSTableView)
        let menu = try #require(table.menu)
        let changeCount = pasteboard.changeCount
        panel.menuNeedsUpdate(menu)
        #expect(menu.items.first?.title == "置顶")
        menu.performActionForItem(at: 0)
        await panel.waitForReload()
        let record = try #require(try await store.page().records.first)
        #expect(record.isPinned && record.title == "needle")
        #expect(pasteboard.changeCount == changeCount)
        #expect(panel.tableView(table, pasteboardWriterForRow: 0) != nil)
        #expect(panel.tableView(table, pasteboardWriterForRow: 1) == nil)
        panel.menuNeedsUpdate(menu)
        #expect(menu.items.first?.title == "取消置顶")
        let row = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        #expect(descendants(row).contains { $0.toolTip == "已置顶" && !$0.isHidden })
        #expect(!descendants(row).contains { $0 is NSButton })

        let search = try #require(window.toolbar?.items.compactMap { $0 as? NSSearchToolbarItem }.first?.searchField)
        search.stringValue = "needle"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        await panel.waitForReload()
        #expect(table.numberOfRows == 1)
        #expect(panel.tableView(table, pasteboardWriterForRow: 0) == nil)
        search.stringValue = "other"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        await panel.waitForReload()
        #expect(table.numberOfRows == 1)
        panel.menuNeedsUpdate(menu)
        #expect(menu.items.first?.title == "置顶")
    }

    @Test func delayedContentActionsPreserveAChangedPasteboardAndDeletedEntriesStayDeleted() async throws {
        let suite = "app.suse.clipboard-actions.\(UUID())"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        let pasteboard = NSPasteboard.withUniqueName()
        let url = FileManager.default.temporaryDirectory.appending(path: "\(suite)/history.sqlite")
        defer {
            settings.defaults.removePersistentDomain(forName: suite)
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let store = ClipboardStore(settings: settings, pasteboard: pasteboard, persistenceURL: url,
            source: { ClipboardSource(name: "Fixture", bundleIdentifier: "com.example.fixture") })
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        store.checkForChanges()
        let record = try #require(try await store.page().records.first)
        let expectedChange = store.pasteboardChangeCount
        let entry = try await store.content(for: record)
        pasteboard.clearContents()
        pasteboard.setString("new clipboard", forType: .string)
        #expect(!store.copy(entry, expectedChangeCount: expectedChange))
        #expect(pasteboard.string(forType: .string) == "new clipboard")
        store.remove(record)
        await #expect(throws: ClipboardStorageError.self) { try await store.content(for: record) }
        #expect(pasteboard.string(forType: .string) == "new clipboard")
        #expect(!(await store.edit(record, text: "resurrection")))
        #expect(try await store.page().total == 0)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
