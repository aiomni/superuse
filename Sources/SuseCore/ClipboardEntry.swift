import Foundation

public enum ClipboardContent: Equatable, Sendable {
    case text(String)
    case image(Data)

    public var preview: String {
        switch self {
        case .text(let text): String(text.prefix(300)).replacingOccurrences(of: "\n", with: " ")
        case .image: "图片"
        }
    }

    public var byteCount: Int {
        switch self {
        case .text(let value): value.utf8.count
        case .image(let data): data.count
        }
    }
}

public struct ClipboardEntry: Identifiable, Equatable, Sendable {
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
