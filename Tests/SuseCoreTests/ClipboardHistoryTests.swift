import Foundation
import Testing
@testable import SuseCore

@Test func deduplicationAndRecency() {
    var history = ClipboardHistory(countLimit: 2)
    for text in ["one", "two", "one"] { history.insert(.init(content: .text(text), source: "test")) }
    #expect(history.entries.map(\.content) == [.text("one"), .text("two")])
    history.insert(.init(content: .text("three"), source: "test"))
    #expect(history.entries.map(\.content) == [.text("three"), .text("one")])
}

@Test func byteLimitsAndInvalidEditsPreserveHistory() {
    var history = ClipboardHistory(countLimit: 10, byteLimit: 8, itemByteLimit: 6)
    let first = ClipboardEntry(content: .text("12345"), source: "test")
    let inserted = history.insert(first)
    let edited = history.edit(id: first.id, text: "")
    let oversized = history.insert(.init(content: .text("1234567"), source: "test"))
    #expect(inserted)
    #expect(!edited)
    #expect(!oversized)
    #expect(history.entries == [first])
    history.insert(.init(content: .text("6789"), source: "test"))
    #expect(history.entries.count == 1)
    history.countLimit = 0
    #expect(history.entries.isEmpty)
}

@Test func restorationDeduplicatesAndEditingKeepsIdentity() throws {
    let original = ClipboardEntry(content: .text("hello"), source: "Editor")
    let encoded = try JSONEncoder().encode([original, original])
    var history = ClipboardHistory()
    history.restore(try JSONDecoder().decode([ClipboardEntry].self, from: encoded))
    #expect(history.entries == [original])
    let edited = history.edit(id: original.id, text: "updated")
    #expect(edited)
    #expect(history.entries.first?.id == original.id)
    #expect(history.entries.first?.matches("UPDATE") == true)
    #expect(history.entries.first?.matches("Editor") == true)
}

@Test func shortcutValidation() {
    #expect(!Shortcut(keyCode: 0, modifiers: [.shift]).isValidGlobalShortcut)
    #expect(Shortcut(keyCode: 9).displayValue == "⌃⌥V")
}
