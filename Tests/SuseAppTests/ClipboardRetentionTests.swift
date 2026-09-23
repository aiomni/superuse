import AppKit
import Testing
import SuseCore
@testable import Suse

@Suite(.serialized)
@MainActor
struct ClipboardRetentionTests {
    @Test func cancellingPreservesSettingsAndDataAndConfirmationKeepsPinnedPlusLatest() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        for text in ["pinned first", "pinned second", "old", "newer", "latest"] {
            fixture.capture(text)
            if text.hasPrefix("pinned") {
                let record = try #require(try await store.page().records.first { $0.title == text })
                store.setPinned(record, pinned: true)
            }
        }
        let initial = try await store.page().records
        var prompts: [ClipboardRetentionPlan] = []
        let view = ClipboardRetentionSettingsView(store: store) { plan, _ in
            prompts.append(plan)
            return prompts.count > 1
        }
        let field = try #require(descendants(view).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        field.stringValue = "1"
        await view.apply()
        #expect(prompts == [.init(limit: 1, pinnedCount: 2, ordinaryCount: 3)])
        #expect(store.countLimit == 1000)
        #expect(field.stringValue == "1000")
        #expect(try await store.page().records == initial)
        field.stringValue = "1"
        await view.apply()
        #expect(store.countLimit == 1)
        #expect(try await store.page().records.map(\.title) == ["pinned second", "pinned first", "latest"])
        fixture.capture("next")
        #expect(try await store.page().records.map(\.title) == ["pinned second", "pinned first", "next"])
        let reopened = ClipboardStore(settings: fixture.settings, pasteboard: fixture.pasteboard, persistenceURL: fixture.url,
            source: { ClipboardSource(name: "Fixture", bundleIdentifier: "com.example.fixture") })
        #expect(try await reopened.page().total == 3)
        #expect(reopened.countLimit == 1)
    }

    @Test func changedDeletionCountsRequireANewConfirmationBeforeApplying() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        for text in ["first", "second", "third"] { fixture.capture(text) }
        var plans: [ClipboardRetentionPlan] = []
        let view = ClipboardRetentionSettingsView(store: fixture.store) { plan, _ in
            plans.append(plan)
            if plans.count == 1 {
                fixture.capture("arrived while confirming")
                await fixture.store.flush()
                return true
            }
            return false
        }
        let field = try #require(descendants(view).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        field.stringValue = "1"
        await view.apply()
        #expect(plans.map(\.removedCount) == [2, 3])
        #expect(fixture.store.countLimit == 1000)
        #expect(try await fixture.store.page().total == 4)
    }

    @Test func invalidInputDoesNotMutateAndIncreasingRetentionDoesNotPrompt() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.capture("kept")
        var prompts = 0
        let view = ClipboardRetentionSettingsView(store: fixture.store) { _, _ in prompts += 1; return true }
        let field = try #require(descendants(view).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        for invalid in ["0", "-8", "2.5", String(Int.max) + "0"] {
            field.stringValue = invalid
            await view.apply()
            #expect(fixture.store.countLimit == 1000)
        }
        field.stringValue = String(Int.max)
        await view.apply()
        #expect(fixture.store.countLimit == Int.max)
        #expect(try await fixture.store.page().total == 1)
        #expect(prompts == 0)
    }

    @Test func existingPreferencesArePreservedAndStoppedRecordingKeepsHistory() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.settings.defaults.set(200, forKey: "clipboard.limit")
        let settings = SettingsStore(defaults: fixture.settings.defaults)
        #expect(settings.clipboardLimit == 200)
        fixture.capture("saved")
        await fixture.store.flush()
        fixture.settings.defaults.set(false, forKey: "clipboard.enabled")
        fixture.capture("not recorded")
        #expect(try await fixture.store.page().records.map(\.title) == ["saved"])
        let reopened = ClipboardStore(settings: settings, pasteboard: fixture.pasteboard, persistenceURL: fixture.url,
            source: { ClipboardSource(name: "Fixture", bundleIdentifier: "com.example.fixture") })
        #expect(try await reopened.page().total == 1)
    }

    @Test func stoppingAndCancellingReadsStillFlushesAcceptedWrites() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        for text in ["first", "second", "third"] { fixture.capture(text) }
        fixture.store.start()
        let read = Task { try await fixture.store.page() }
        read.cancel()
        fixture.store.stop()
        await fixture.store.flush()
        await #expect(throws: CancellationError.self) { try await read.value }
        let reopened = ClipboardStore(settings: fixture.settings, pasteboard: fixture.pasteboard, persistenceURL: fixture.url,
            source: { ClipboardSource(name: "Fixture", bundleIdentifier: "com.example.fixture") })
        #expect(try await reopened.page().total == 3)
    }

    @Test func excludedSourcesAreNotRecordedOrWritten() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.settings.defaults.set("com.example.fixture", forKey: "clipboard.excludedApps")
        fixture.capture("excluded")
        #expect(try await fixture.store.page().total == 0)
        fixture.settings.defaults.set("", forKey: "clipboard.excludedApps")
        fixture.capture("allowed")
        #expect(try await fixture.store.page().records.map(\.title) == ["allowed"])
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    @MainActor
    private final class Fixture {
        let suite = "app.suse.retention.\(UUID())"
        let settings: SettingsStore
        let pasteboard = NSPasteboard.withUniqueName()
        let url: URL
        let store: ClipboardStore

        init() {
            _ = NSApplication.shared
            settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
            url = FileManager.default.temporaryDirectory.appending(path: "\(suite)/history.sqlite")
            store = ClipboardStore(settings: settings, pasteboard: pasteboard, persistenceURL: url,
            source: { ClipboardSource(name: "Fixture", bundleIdentifier: "com.example.fixture") })
        }

        func capture(_ text: String) {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            store.checkForChanges()
        }

        func cleanup() {
            settings.defaults.removePersistentDomain(forName: suite)
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }
}
