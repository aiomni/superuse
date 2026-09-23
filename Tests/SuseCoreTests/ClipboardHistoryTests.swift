import Foundation
import Testing
@testable import SuseCore

@Test func legacyClipboardEntryUsesCaptureTimeAsModificationTime() throws {
    let id = UUID()
    let json = """
        [{"id":"\(id)","content":{"text":{"_0":"hello"}},"capturedAt":42,"source":"Editor"}]
        """
    let entry = try #require(JSONDecoder().decode([ClipboardEntry].self, from: Data(json.utf8)).first)
    #expect(entry.id == id)
    #expect(entry.modifiedAt == entry.capturedAt)
    #expect(entry.matches("HELLO"))
    #expect(entry.matches("editor"))
    #expect(try JSONDecoder().decode(ClipboardEntry.self, from: JSONEncoder().encode(entry)) == entry)
}

@Test func clipboardPreviewDoesNotChangeOriginalText() {
    let text = "first\n" + String(repeating: "内容", count: 500)
    let entry = ClipboardEntry(content: .text(text), source: "Editor")
    #expect(entry.title.count == 300)
    #expect(!entry.title.contains("\n"))
    #expect(entry.content == .text(text))
}

@Test func shortcutValidation() {
    #expect(!Shortcut(keyCode: 0, modifiers: [.shift]).isValidGlobalShortcut)
    #expect(Shortcut(keyCode: 9).displayValue == "⌃⌥V")
}

@Test func retentionAcceptsPositiveCountsWithoutPresetCeilings() {
    #expect(ClipboardRetention.defaultLimit == 1000)
    for value in [1, 50, 1000, 500_000, Int.max] {
        #expect(ClipboardRetention.parseLimit(" \(value)\n") == value)
    }
    for value in ["", "0", "-1", "1.5", "1e6", "abc", String(Int.max) + "0"] {
        #expect(ClipboardRetention.parseLimit(value) == nil)
    }
    let plan = ClipboardRetentionPlan(limit: 50, pinnedCount: 80, ordinaryCount: 200)
    #expect(plan.pinnedCount == 80)
    #expect(plan.retainedOrdinaryCount == 50)
    #expect(plan.removedCount == 150)
}
