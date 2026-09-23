import AppKit
import SuseCore

@MainActor
final class ClipboardRowView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("clipboard.row")
    private let icon = NSImageView()
    private let title = UI.label("", size: 13, weight: .medium)
    private let subtitle = UI.label("", size: 11, color: .secondaryLabelColor)
    private let pinned = NSImageView(image: NSImage(systemSymbolName: "pin.circle.fill", accessibilityDescription: "已置顶")!)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .secondaryLabelColor
        let contentIcon = NSView()
        contentIcon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        contentIcon.heightAnchor.constraint(equalToConstant: 32).isActive = true
        contentIcon.addSubview(icon)
        UI.pin(icon, to: contentIcon)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        let labels = UI.stack([title, subtitle], spacing: 3)
        pinned.symbolConfiguration = NSImage.SymbolConfiguration(paletteColors: [.labelColor, .controlBackgroundColor])
        pinned.toolTip = "已置顶"
        pinned.setAccessibilityLabel("已置顶")
        contentIcon.addSubview(pinned)
        pinned.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pinned.widthAnchor.constraint(equalToConstant: 16),
            pinned.heightAnchor.constraint(equalToConstant: 16),
            pinned.trailingAnchor.constraint(equalTo: contentIcon.trailingAnchor),
            pinned.bottomAnchor.constraint(equalTo: contentIcon.bottomAnchor),
        ])
        let content = UI.stack([contentIcon, labels], axis: .horizontal, spacing: 10)
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
