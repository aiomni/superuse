import Foundation

public enum ClipboardContent: Codable, Equatable, Sendable {
    case text(String)
    case image(Data)

    public var byteCount: Int {
        switch self {
        case .text(let value): value.utf8.count
        case .image(let data): data.count
        }
    }
}

public struct ClipboardEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let content: ClipboardContent
    public let capturedAt: Date
    public let source: String

    public init(id: UUID = UUID(), content: ClipboardContent, capturedAt: Date = Date(), source: String) {
        self.id = id
        self.content = content
        self.capturedAt = capturedAt
        self.source = source
    }

    public var title: String {
        switch content {
        case .text(let text): String(text.prefix(300)).replacingOccurrences(of: "\n", with: " ")
        case .image: "图片"
        }
    }

    public func matches(_ query: String) -> Bool {
        query.isEmpty || source.localizedCaseInsensitiveContains(query) || {
            if case .text(let text) = content { return text.localizedCaseInsensitiveContains(query) }
            return "图片 image".localizedCaseInsensitiveContains(query)
        }()
    }
}

/// A bounded, most-recent-first history. All entry points preserve the same limits.
public struct ClipboardHistory: Sendable {
    public private(set) var entries: [ClipboardEntry] = []
    public var countLimit: Int { didSet { trim() } }
    public let byteLimit: Int
    public let itemByteLimit: Int

    public init(countLimit: Int = 100, byteLimit: Int = 32 * 1_024 * 1_024,
                itemByteLimit: Int = 8 * 1_024 * 1_024) {
        self.countLimit = countLimit
        self.byteLimit = byteLimit
        self.itemByteLimit = itemByteLimit
    }

    @discardableResult
    public mutating func insert(_ entry: ClipboardEntry) -> Bool {
        guard entry.content.byteCount > 0, entry.content.byteCount <= itemByteLimit,
              entry.content.byteCount <= byteLimit else { return false }
        entries.removeAll { $0.content == entry.content || $0.id == entry.id }
        entries.insert(entry, at: 0)
        trim()
        return true
    }

    @discardableResult
    public mutating func edit(id: UUID, text: String) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }), case .text = entry.content else { return false }
        return insert(ClipboardEntry(id: id, content: .text(text), capturedAt: entry.capturedAt, source: entry.source))
    }

    public mutating func remove(id: UUID) { entries.removeAll { $0.id == id } }
    public mutating func removeAll() { entries.removeAll() }

    public mutating func restore(_ saved: [ClipboardEntry]) {
        entries.removeAll()
        for entry in saved.reversed() { insert(entry) }
    }

    private mutating func trim() {
        var bytes = 0
        entries = Array(entries.prefix(max(0, countLimit)).prefix { entry in
            bytes += entry.content.byteCount
            return bytes <= byteLimit
        })
    }
}
