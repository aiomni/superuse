import Foundation
import Testing
import SuseCore
@testable import Suse

@Suite(.serialized)
@MainActor
struct ClipboardListModelTests {
    @Test func changingSearchDiscardsLatePagesAndDoesNotMixQueryResults() async throws {
        let source = DeferredListing()
        defer { source.finishPending() }
        let model = ClipboardListModel(store: source)
        let initial = Task { try await model.refresh(query: "", selectedID: nil) }
        try await source.waitForRequests(1)
        source.resume(0, with: page(total: 400, offset: 0, title: "old"))
        _ = try await initial.value
        var loadedPages = 0
        model.onPageLoaded = { _ in loadedPages += 1 }
        #expect(model.record(at: 150) == nil)
        try await source.waitForRequests(2)

        let searching = Task { try await model.refresh(query: "new", selectedID: nil) }
        try await source.waitForRequests(3)
        #expect(model.record(at: 250) == nil)
        await Task.yield()
        #expect(source.requests.count == 3)
        source.resume(1, with: page(total: 400, offset: 100, title: "old"))
        let newPage = page(total: 1, offset: 0, title: "new")
        source.resume(2, with: newPage)
        _ = try await searching.value
        #expect(model.total == 1)
        #expect(model.record(at: 0) == newPage.records.first)
        #expect(loadedPages == 0)
    }

    @Test func changedHistoryInvalidatesTheListInsteadOfReloadingInvalidRowRanges() async throws {
        let source = DeferredListing()
        defer { source.finishPending() }
        let model = ClipboardListModel(store: source)
        let initial = Task { try await model.refresh(query: "", selectedID: nil) }
        try await source.waitForRequests(1)
        source.resume(0, with: page(total: 400, offset: 0, title: "initial"))
        _ = try await initial.value
        var invalidated = false
        var loadedPages = 0
        model.onInvalidated = { invalidated = true }
        model.onPageLoaded = { _ in loadedPages += 1 }
        #expect(model.record(at: 350) == nil)
        try await source.waitForRequests(2)
        source.resume(1, with: page(total: 300, offset: 300, title: "deleted"))
        for _ in 0..<100 where !invalidated { await Task.yield() }
        #expect(invalidated)
        #expect(loadedPages == 0)
    }

    private func page(total: Int, offset: Int, title: String) -> ClipboardPage {
        let records = (offset..<min(total, offset + 100)).map { index in
            ClipboardRecord(id: UUID(), isImage: false, title: "\(title) \(index)", source: "Fixture",
                            capturedAt: .distantPast, modifiedAt: .distantPast, fingerprint: "\(title)-\(index)")
        }
        return ClipboardPage(records: records, total: total, offset: offset)
    }

    @MainActor
    private final class DeferredListing: ClipboardListing {
        struct Request { let query: String; let offset: Int }
        var requests: [Request] = []
        private var pending: [Int: CheckedContinuation<ClipboardPage, Error>] = [:]

        func page(query: String, offset: Int, limit: Int) async throws -> ClipboardPage {
            let index = requests.count
            requests.append(Request(query: query, offset: offset))
            return try await withCheckedThrowingContinuation { pending[index] = $0 }
        }

        func index(of id: UUID, query: String) async throws -> Int? { nil }

        func waitForRequests(_ count: Int) async throws {
            for _ in 0..<100 where requests.count < count { await Task.yield() }
            try #require(requests.count >= count)
        }

        func resume(_ request: Int, with page: ClipboardPage) { pending.removeValue(forKey: request)?.resume(returning: page) }

        func finishPending() {
            let continuations = pending.values
            pending.removeAll()
            for continuation in continuations { continuation.resume(throwing: CancellationError()) }
        }
    }
}
