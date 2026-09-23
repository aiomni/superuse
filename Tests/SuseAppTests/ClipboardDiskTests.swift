import Foundation
import Testing
import SuseCore
@testable import Suse

struct ClipboardDiskTests {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "clipboard-tests-\(UUID())/history.sqlite")
    }

    @Test func legacyMigrationPreservesContentIdentityAndPrivatePermissions() async throws {
        let url = location()
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let legacy = url.deletingPathExtension().appendingPathExtension("json")
        let entry = ClipboardEntry(content: .text("migration\nfixture"), capturedAt: Date(timeIntervalSince1970: 100), source: "Fixture")
        try JSONEncoder().encode([entry, entry]).write(to: legacy)
        let disk = ClipboardDisk(url: url)
        try await disk.prepare(limit: 1000)
        let record = try #require(try await disk.page().records.first)
        #expect(record.id == entry.id)
        #expect(try await disk.content(for: record) == entry)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        let restarted = ClipboardDisk(url: url)
        #expect(try await restarted.page().total == 1)
        #expect(try await restarted.content(for: record) == entry)
        for (path, mode) in [(url, 0o600), (directory, 0o700)] {
            let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == mode)
        }
    }

    @Test func failedMigrationLeavesLegacyDataAvailableForRetry() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = url.deletingPathExtension().appendingPathExtension("json")
        let invalid = Data("[unfinished".utf8)
        try invalid.write(to: legacy)
        let disk = ClipboardDisk(url: url)
        await #expect(throws: (any Error).self) { try await disk.prepare(limit: 1000) }
        #expect(try Data(contentsOf: legacy) == invalid)
        let recovered = ClipboardEntry(content: .text("recovered"), source: "Fixture")
        try JSONEncoder().encode([recovered]).write(to: legacy)
        try await disk.prepare(limit: 1000)
        #expect(try await disk.page().total == 1)
    }

    @Test func recaptureAndEditKeepIdentityAndRejectStaleContentActions() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let disk = ClipboardDisk(url: url)
        let first = ClipboardEntry(content: .text("first"), capturedAt: Date(timeIntervalSince1970: 1), source: "Fixture")
        try await disk.capture(first, limit: 2)
        try await disk.capture(.init(content: .text("second"), capturedAt: Date(timeIntervalSince1970: 2), source: "Fixture"), limit: 2)
        try await disk.capture(.init(content: .text("first"), capturedAt: Date(timeIntervalSince1970: 3), source: "New source"), limit: 2)
        let original = try #require(try await disk.page().records.first)
        #expect(original.id == first.id)
        #expect(original.modifiedAt == Date(timeIntervalSince1970: 3))
        #expect(original.source == "New source")
        try await disk.edit(original, text: "second", limit: 2, now: Date(timeIntervalSince1970: 4))
        let updated = try #require(try await disk.page().records.first)
        #expect(try await disk.page().total == 1)
        #expect(updated.id == first.id)
        #expect(updated.title == "second")
        await #expect(throws: ClipboardStorageError.self) { try await disk.content(for: original) }
        await #expect(throws: ClipboardStorageError.self) { try await disk.edit(updated, text: "", limit: 2) }
        #expect(try await disk.content(for: updated).content == .text("second"))
        try await disk.remove(id: updated.id)
        await #expect(throws: ClipboardStorageError.self) { try await disk.content(for: updated) }
    }

    @Test func pagingAndUnicodeSearchReachRecordsOutsideTheFirstPage() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entries = (0..<1200).map {
            ClipboardEntry(content: .text("行 \($0)\u{0} " + ($0 == 5 ? "École Needle" : "regular")),
                           capturedAt: Date(timeIntervalSince1970: Double($0)), source: "Fixture")
        }
        try JSONEncoder().encode(entries.reversed()).write(to: url.deletingPathExtension().appendingPathExtension("json"))
        let disk = ClipboardDisk(url: url)
        try await disk.prepare(limit: 2000)
        let first = try await disk.page()
        let last = try await disk.page(offset: 1100)
        #expect(first.total == 1200 && first.records.count == 100)
        #expect(last.records.count == 100)
        #expect(last.records.last?.id == entries.first?.id)
        let matched = try await disk.page(query: "éCOLE needle")
        #expect(matched.records.map(\.id) == [entries[5].id])
        #expect(try await disk.content(for: matched.records[0]).content == entries[5].content)
        #expect(try await disk.index(of: entries[5].id, query: "") == 1194)
        #expect(try await disk.page(query: "fixture", offset: 1190).records.count == 10)
    }

    @Test func historyAcceptsItemsAndTotalsAboveTheFormerByteLimits() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let disk = ClipboardDisk(url: url)
        let body = String(repeating: "a", count: 9 * 1024 * 1024)
        for number in 0..<4 {
            try await disk.capture(.init(content: .text("\(number)" + body), source: "Fixture"), limit: 1000)
        }
        let page = try await disk.page()
        #expect(page.total == 4)
        #expect(page.records.allSatisfy { $0.title.utf8.count == 300 })
        let record = try #require(page.records.first)
        #expect(try await disk.content(for: record).content.byteCount == body.utf8.count + 1)
        try await disk.clear()
        #expect(try await disk.page().total == 0)
        let remainingBytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        #expect(remainingBytes < 512 * 1024)
    }
}

extension ClipboardDiskTests {
    @Test func pinnedHistoryIsAdditionalToOrdinaryRetentionAndKeepsItsPosition() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let disk = ClipboardDisk(url: url)
        var ids: [UUID] = []
        for number in 0..<5 {
            let entry = ClipboardEntry(content: .text("entry \(number)"), capturedAt: Date(timeIntervalSince1970: Double(number)), source: "Fixture")
            ids.append(entry.id)
            try await disk.capture(entry, limit: 2)
            if number < 2 { try await disk.setPinned(id: entry.id, pinned: true, limit: 2) }
        }
        #expect(try await disk.page().records.map(\.id) == [ids[1], ids[0], ids[4], ids[3]])
        try await disk.capture(.init(content: .text("entry 0"), capturedAt: Date(timeIntervalSince1970: 10), source: "Again"), limit: 2)
        var record = try #require(try await disk.page().records.first { $0.id == ids[0] })
        #expect(record.modifiedAt == Date(timeIntervalSince1970: 10))
        #expect(try await disk.page().records.first?.id == ids[1])
        try await disk.edit(record, text: "edited", limit: 2, now: Date(timeIntervalSince1970: 20))
        record = try #require(try await disk.page().records.first { $0.id == ids[0] })
        #expect(record.isPinned)
        #expect(try await disk.page().records.map(\.id) == [ids[1], ids[0], ids[4], ids[3]])
        try await disk.setPinned(id: ids[0], pinned: false, limit: 2)
        #expect(try await disk.page().records.map(\.id) == [ids[1], ids[0], ids[4]])
        #expect(try await disk.counts().pinned == 1)
        #expect(try await disk.counts().ordinary == 2)
        #expect(try await disk.page(query: "edited").records.map(\.id) == [ids[0]])
        try await disk.clear()
        #expect(try await disk.page().total == 0)
    }

    @Test func manualPinnedOrderSurvivesNewPinsRecaptureAndRestart() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let disk = ClipboardDisk(url: url)
        let entries = (0..<4).map { ClipboardEntry(content: .text("entry \($0)"), source: "Fixture") }
        for entry in entries.prefix(3) {
            try await disk.capture(entry, limit: 1)
            try await disk.setPinned(id: entry.id, pinned: true, limit: 1)
        }
        try await disk.movePinned(id: entries[0].id, before: entries[2].id)
        #expect(try await disk.page().records.map(\.id) == [entries[0].id, entries[2].id, entries[1].id])
        try await disk.capture(entries[3], limit: 1)
        try await disk.setPinned(id: entries[3].id, pinned: true, limit: 1)
        try await disk.capture(.init(content: entries[1].content, source: "Again"), limit: 1)
        #expect(try await disk.page().records.map(\.id) == [entries[3].id, entries[0].id, entries[2].id, entries[1].id])
        try await disk.movePinned(id: entries[3].id, before: nil)
        let restarted = ClipboardDisk(url: url)
        #expect(try await restarted.page().records.map(\.id) == [entries[0].id, entries[2].id, entries[1].id, entries[3].id])
        try await disk.setPinned(id: entries[2].id, pinned: false, limit: 1)
        await #expect(throws: ClipboardStorageError.self) { try await disk.movePinned(id: entries[2].id, before: entries[0].id) }
        try await disk.setPinned(id: entries[2].id, pinned: true, limit: 1)
        #expect(try await disk.page().records.first?.id == entries[2].id)
    }

    @Test(arguments: [0, 1, 2, 3])
    func editingDuplicatePreservesEitherPinnedState(mask: Int) async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let disk = ClipboardDisk(url: url)
        let first = ClipboardEntry(content: .text("first"), source: "Fixture")
        let second = ClipboardEntry(content: .text("second"), source: "Fixture")
        try await disk.capture(first, limit: 10)
        try await disk.capture(second, limit: 10)
        if mask & 1 != 0 { try await disk.setPinned(id: first.id, pinned: true, limit: 10) }
        if mask & 2 != 0 { try await disk.setPinned(id: second.id, pinned: true, limit: 10) }
        let record = try #require(try await disk.page().records.first { $0.id == first.id })
        let other = try #require(try await disk.page().records.first { $0.id == second.id })
        try await disk.edit(record, text: "second", limit: 10)
        let merged = try #require(try await disk.page().records.first)
        #expect(try await disk.page().total == 1)
        #expect(merged.id == first.id)
        #expect(merged.isPinned == (mask != 0))
        #expect(merged.pinOrder == (record.pinOrder ?? other.pinOrder))
    }
}
