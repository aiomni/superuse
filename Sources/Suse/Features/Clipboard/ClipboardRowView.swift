import AppKit
import SuseCore

@MainActor
final class ClipboardRowView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("clipboard.row")
    private let icon = NSImageView()
    private let title = UI.label("", size: 13, weight: .medium)
    private let subtitle = UI.label("", size: 11, color: .secondaryLabelColor)
    private let pinned = NSImageView(image: NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "已置顶")!)

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
        pinned.contentTintColor = .secondaryLabelColor
        pinned.toolTip = "已置顶"
        pinned.setAccessibilityLabel("已置顶")
        pinned.widthAnchor.constraint(equalToConstant: 14).isActive = true
        pinned.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let content = UI.stack([icon, labels, pinned], axis: .horizontal, spacing: 10)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(content)
        UI.pin(content, to: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(with record: ClipboardRecord?) {
        guard let record else {
            icon.image = nil
            title.stringValue = "正在加载…"
            subtitle.stringValue = ""
            pinned.isHidden = true
            setAccessibilityLabel("正在加载记录")
            return
        }
        icon.image = record.thumbnail.flatMap(NSImage.init(data:))
            ?? NSImage(systemSymbolName: record.isImage ? "photo" : "text.alignleft", accessibilityDescription: record.isImage ? "图片" : "文本")
        title.stringValue = record.title.isEmpty ? "空白文本" : record.title
        subtitle.stringValue = "\(record.source) · \(record.modifiedAt.formatted(date: .omitted, time: .shortened))"
        pinned.isHidden = !record.isPinned
        setAccessibilityLabel("\(record.isPinned ? "已置顶，" : "")\(record.title)，来自 \(record.source)")
    }
}
