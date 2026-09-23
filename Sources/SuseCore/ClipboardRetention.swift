import Foundation

public enum ClipboardRetention {
    public static let defaultLimit = 1000

    public static func parseLimit(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else { return nil }
        return value
    }
}

/// The concrete effect shown before changing retention. Pinned entries never consume ordinary slots.
public struct ClipboardRetentionPlan: Equatable, Sendable {
    public let limit: Int
    public let pinnedCount: Int
    public let ordinaryCount: Int
    public var retainedOrdinaryCount: Int { min(ordinaryCount, limit) }
    public var removedCount: Int { max(0, ordinaryCount - limit) }

    public init(limit: Int, pinnedCount: Int, ordinaryCount: Int) {
        self.limit = limit
        self.pinnedCount = pinnedCount
        self.ordinaryCount = ordinaryCount
    }
}
