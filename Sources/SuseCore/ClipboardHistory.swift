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
    public let modifiedAt: Date

    public init(id: UUID = UUID(), content: ClipboardContent, capturedAt: Date = Date(), source: String,
                modifiedAt: Date? = nil) {
        self.id = id
        self.content = content
        self.capturedAt = capturedAt
        self.source = source
        self.modifiedAt = modifiedAt ?? capturedAt
    }

    private enum CodingKeys: String, CodingKey { case id, content, capturedAt, source, modifiedAt }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        content = try values.decode(ClipboardContent.self, forKey: .content)
        capturedAt = try values.decode(Date.self, forKey: .capturedAt)
        source = try values.decode(String.self, forKey: .source)
        modifiedAt = try values.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? capturedAt
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

/// A list projection. Original text and image bytes are read only for an explicit content action.
public struct ClipboardRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let isImage: Bool
    public let title: String
    public let source: String
    public let capturedAt: Date
    public let modifiedAt: Date
    public let fingerprint: String
    public let pinOrder: Int?
    public let thumbnail: Data?
    public var isPinned: Bool { pinOrder != nil }

    public init(id: UUID, isImage: Bool, title: String, source: String, capturedAt: Date, modifiedAt: Date,
                fingerprint: String, pinOrder: Int? = nil, thumbnail: Data? = nil) {
        self.id = id
        self.isImage = isImage
        self.title = title
        self.source = source
        self.capturedAt = capturedAt
        self.modifiedAt = modifiedAt
        self.fingerprint = fingerprint
        self.pinOrder = pinOrder
        self.thumbnail = thumbnail
    }
}

public struct ClipboardPage: Sendable {
    public let records: [ClipboardRecord]
    public let total: Int
    public let offset: Int

    public init(records: [ClipboardRecord], total: Int, offset: Int) {
        self.records = records
        self.total = total
        self.offset = offset
    }
}
