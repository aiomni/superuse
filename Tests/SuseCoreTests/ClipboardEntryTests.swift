import Foundation
import Testing
@testable import SuseCore

@Test func clipboardPreviewDoesNotChangeOriginalText() {
    let text = "first\n" + String(repeating: "内容", count: 500)
    let entry = ClipboardEntry(content: .text(text), source: "Editor")
    #expect(entry.content.preview.count == 300)
    #expect(!entry.content.preview.contains("\n"))
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
