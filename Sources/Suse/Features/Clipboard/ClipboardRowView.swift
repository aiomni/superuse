import AppKit
import SuseCore

@MainActor
final class ClipboardRowView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("clipboard.row")
    private let icon = NSImageView()
    private let title = UI.label("", size: 13, weight: .medium)
    private let subtitle = UI.label("", size: 11, color: .secondaryLabelColor)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 32).isActive = true
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        let labels = UI.stack([title, subtitle], spacing: 3)
        let content = UI.stack([icon, labels], axis: .horizontal, spacing: 10)
        addSubview(content)
        UI.pin(content, to: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(with record: ClipboardRecord?) {
        guard let record else {
            icon.image = nil
            title.stringValue = "正在加载…"
            subtitle.stringValue = ""
            setAccessibilityLabel("正在加载记录")
            return
        }
        icon.image = record.thumbnail.flatMap(NSImage.init(data:))
            ?? NSImage(systemSymbolName: record.isImage ? "photo" : "text.alignleft", accessibilityDescription: record.isImage ? "图片" : "文本")
        title.stringValue = record.title.isEmpty ? "空白文本" : record.title
        subtitle.stringValue = "\(record.source) · \(record.modifiedAt.formatted(date: .omitted, time: .shortened))"
        setAccessibilityLabel("\(record.title)，来自 \(record.source)")
    }
}
