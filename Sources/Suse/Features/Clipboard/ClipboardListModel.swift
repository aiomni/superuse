import Foundation
import SuseCore

@MainActor
protocol ClipboardListing: AnyObject {
    func page(query: String, offset: Int, limit: Int) async throws -> ClipboardPage
    func index(of id: UUID, query: String) async throws -> Int?
}

/// A bounded cache of list summaries, independent of how many records are on disk.
@MainActor
final class ClipboardListModel {
    private let store: any ClipboardListing
    private let pageSize = 100
    private let cachedPageLimit = 5
    private var pages: [Int: [ClipboardRecord]] = [:]
    private var recentPages: [Int] = []
    private var requests: [Int: Task<Void, Never>] = [:]
    private var generation = 0
    private var refreshing = false
    private(set) var query = ""
    private(set) var total = 0
    var onPageLoaded: ((Range<Int>) -> Void)?
    var onError: ((Error) -> Void)?
    var onInvalidated: (() -> Void)?

    init(store: any ClipboardListing) { self.store = store }

    func refresh(query: String, selectedID: UUID?) async throws -> Int? {
        cancelRequests()
        generation += 1
        let version = generation
        refreshing = true
        defer { if generation == version { refreshing = false } }
        self.query = query
        let index: Int
        if let selectedID { index = try await store.index(of: selectedID, query: query) ?? 0 }
        else { index = 0 }
        let page = try await store.page(query: query, offset: index / pageSize * pageSize, limit: pageSize)
        try Task.checkCancellation()
        guard version == generation else { throw CancellationError() }
        pages.removeAll()
        recentPages.removeAll()
        total = page.total
        cache(page)
        return total == 0 ? nil : min(index, total - 1)
    }

    func record(at row: Int) -> ClipboardRecord? {
        guard row >= 0, row < total else { return nil }
        let pageIndex = row / pageSize
        guard let page = pages[pageIndex] else {
            if !refreshing { request(pageIndex) }
            return nil
        }
        touch(pageIndex)
        let offset = row % pageSize
        return page.indices.contains(offset) ? page[offset] : nil
    }

    func cancelRequests() {
        requests.values.forEach { $0.cancel() }
        requests.removeAll()
    }

    private func request(_ pageIndex: Int) {
        guard requests[pageIndex] == nil else { return }
        // Rapid scrolling should replace obsolete reads instead of building an unbounded queue.
        if requests.count >= 3, let farthest = requests.keys.max(by: { abs($0 - pageIndex) < abs($1 - pageIndex) }) {
            requests.removeValue(forKey: farthest)?.cancel()
        }
        let version = generation
        let query = query
        requests[pageIndex] = Task { [weak self, store, pageSize] in
            do {
                try Task.checkCancellation()
                let page = try await store.page(query: query, offset: pageIndex * pageSize, limit: pageSize)
                try Task.checkCancellation()
                guard let self, version == generation else { return }
                requests[pageIndex] = nil
                guard page.total == total else { onInvalidated?(); return }
                cache(page)
                onPageLoaded?(page.offset..<(page.offset + page.records.count))
            } catch is CancellationError { }
            catch {
                guard let self, version == generation else { return }
                requests[pageIndex] = nil
                onError?(error)
            }
        }
    }

    private func cache(_ page: ClipboardPage) {
        let index = page.offset / pageSize
        pages[index] = page.records
        touch(index)
        while recentPages.count > cachedPageLimit { pages[recentPages.removeFirst()] = nil }
    }

    private func touch(_ index: Int) {
        recentPages.removeAll { $0 == index }
        recentPages.append(index)
    }
}
