import AppKit

enum PinSource: Equatable {
    case screenshot
    case clipboard(UUID)
}

/// Inputs cross feature boundaries without reading or writing the system pasteboard.
@MainActor
struct PinRequest {
    enum Content {
        case image(CGImage, pointSize: CGSize)
        case imageData(Data, scale: CGFloat)
        case text(String)
    }

    let content: Content
    let source: PinSource
    var preferredFrame: CGRect? = nil
}

@MainActor
protocol PinPresenting: AnyObject {
    func pin(_ request: PinRequest) throws
    func suspendForCapture() -> UUID
    func resumeAfterCapture(_ token: UUID)
    /// nil means every clipboard-derived Pin, including entries already evicted from history.
    func closeClipboardPins(entryID: UUID?)
}
