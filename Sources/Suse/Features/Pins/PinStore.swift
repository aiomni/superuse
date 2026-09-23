import AppKit
import ImageIO
import SuseCore

@MainActor
struct PinItem: Identifiable {
    enum Content {
        case image(CGImage, pointSize: CGSize)
        case text(String)
    }

    let id: UUID
    var content: Content
    let source: PinSource
    let preferredFrame: CGRect?
    var byteCount: Int
    var isHidden = false
    var isClickThrough = false
    var opacity = 1.0

    var title: String {
        switch content {
        case .image(let image, _): "图片 · \(image.width) × \(image.height)"
        case .text(let text) where text.isEmpty: "文字 · 空白"
        case .text(let text): "文字 · " + String(text.prefix(40)).components(separatedBy: .newlines).joined(separator: " ")
        }
    }

    var pointSize: CGSize {
        switch content {
        case .image(_, let size): size
        case .text: CGSize(width: 360, height: 220)
        }
    }
}

/// Session-only snapshots. User visibility and capture suppression are independent.
@MainActor
final class PinStore {
    private(set) var items: [PinItem] = []
    private var captureTokens: Set<UUID> = []
    let limits: PinResourceLimits
    var onChange: (() -> Void)?

    init(limits: PinResourceLimits = PinResourceLimits()) { self.limits = limits }

    var byteCount: Int { items.reduce(0) { $0 + $1.byteCount } }
    var allHidden: Bool { !items.isEmpty && items.allSatisfy(\.isHidden) }
    var isCapturing: Bool { !captureTokens.isEmpty }

    func isVisible(_ item: PinItem) -> Bool { !item.isHidden && !isCapturing }

    @discardableResult
    func insert(_ request: PinRequest) throws -> UUID {
        guard items.count < limits.count else { throw AppError("Pin 数量已达上限，请先关闭一些悬浮内容。") }
        let content: PinItem.Content
        let cost: Int
        switch request.content {
        case .text(let text):
            guard !text.isEmpty else { throw AppError("无法 Pin 空内容。") }
            // Account for both the UTF-8 snapshot and NSTextView's UTF-16 backing.
            cost = Self.textCost(text)
            content = .text(text)
        case .image(let image, let size):
            try validateImageSize(width: image.width, height: image.height)
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
                throw AppError("图片显示尺寸无效。")
            }
            try validateCost(image.width * image.height * 4)
            // A cropped CGImage can retain the entire frozen display. Own only this crop.
            let snapshot = try detachedSnapshot(image)
            cost = try imageCost(snapshot)
            content = .image(snapshot, pointSize: size)
        case .imageData(let data, let scale):
            guard scale.isFinite, scale > 0,
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
                throw AppError("无法读取这张图片。")
            }
            try validateImageSize(width: width, height: height)
            let depth = (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 8
            guard depth > 0, depth <= 32 else { throw AppError("不支持这张图片的颜色深度。") }
            let estimated = width * height * max(4, ((depth + 7) / 8) * 4) + data.count
            try validateCost(estimated)
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                throw AppError("图片已损坏，无法 Pin。")
            }
            cost = try imageCost(image) + data.count
            content = .image(image, pointSize: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
        }
        try validateCost(cost)
        let id = UUID()
        items.append(PinItem(id: id, content: content, source: request.source,
                             preferredFrame: request.preferredFrame, byteCount: cost))
        onChange?()
        return id
    }

    private func validateImageSize(width: Int, height: Int) throws {
        guard limits.acceptsImage(width: width, height: height) else { throw AppError("图片过大，Pin 最多支持 48 MP。") }
    }

    private func imageCost(_ image: CGImage) throws -> Int {
        let (bytes, overflow) = max(image.bytesPerRow, image.width * 4).multipliedReportingOverflow(by: image.height)
        guard !overflow else { throw AppError("图片过大，无法 Pin。") }
        return bytes
    }

    private func detachedSnapshot(_ image: CGImage) throws -> CGImage {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AppError("无法为 Pin 创建图片快照。")
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let snapshot = context.makeImage() else { throw AppError("无法为 Pin 创建图片快照。") }
        return snapshot
    }

    private func validateCost(_ cost: Int) throws {
        guard limits.accepts(bytes: cost, currentBytes: byteCount, currentCount: items.count) else {
            throw AppError("Pin 内存已达上限，请先关闭一些悬浮内容。")
        }
    }

    private static func textCost(_ text: String) -> Int { text.utf8.count + text.utf16.count * 2 }

    func validateTextUpdate(_ text: String, for id: UUID) throws {
        guard let item = items.first(where: { $0.id == id }), case .text = item.content else {
            throw AppError("此文字 Pin 已关闭。")
        }
        // Editing replaces an existing allocation; it is allowed at the window-count limit and may be empty.
        guard Self.textCost(text) <= limits.bytes - (byteCount - item.byteCount) else {
            throw AppError("Pin 内存已达上限，请缩短文字或关闭其他 Pin 后重试。")
        }
    }

    func updateText(_ text: String, for id: UUID) throws {
        try validateTextUpdate(text, for: id)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].content = .text(text)
        items[index].byteCount = Self.textCost(text)
        onChange?()
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id }; onChange?() }
    func removeAll() { items.removeAll(); onChange?() }

    func endSession() {
        items.removeAll()
        captureTokens.removeAll()
        onChange?()
    }

    func closeClipboardPins(entryID: UUID?) {
        items.removeAll {
            guard case .clipboard(let id) = $0.source else { return false }
            return entryID == nil || entryID == id
        }
        onChange?()
    }

    func setOpacity(_ opacity: Double, for id: UUID) {
        guard opacity.isFinite, let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].opacity = min(1, max(0.3, opacity))
        onChange?()
    }

    func setClickThrough(_ enabled: Bool, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isClickThrough = enabled
        onChange?()
    }

    func toggleVisibility() {
        let hidden = !allHidden
        for index in items.indices { items[index].isHidden = hidden }
        onChange?()
    }

    func reveal(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isHidden = false
        items[index].isClickThrough = false
        onChange?()
    }

    func restoreInteraction() {
        for index in items.indices {
            items[index].isHidden = false
            items[index].isClickThrough = false
        }
        onChange?()
    }

    func suspendForCapture() -> UUID {
        let token = UUID()
        captureTokens.insert(token)
        onChange?()
        return token
    }

    func resumeAfterCapture(_ token: UUID) {
        guard captureTokens.remove(token) != nil else { return }
        onChange?()
    }
}
