import AppKit

@MainActor
enum UI {
    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    static func stack(_ views: [NSView], axis: NSUserInterfaceLayoutOrientation = .vertical,
                      spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = axis
        stack.alignment = axis == .vertical ? .leading : .centerY
        stack.spacing = spacing
        return stack
    }

    static func pin(_ child: NSView, to parent: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
        ])
    }

    static func padded(_ content: NSView, inset: CGFloat = 20) -> NSView {
        let wrapper = NSView()
        wrapper.addSubview(content)
        pin(content, to: wrapper, inset: inset)
        return wrapper
    }

    /// Glass belongs to floating controls, never to documents, lists, or settings content.
    static func glassBar(_ controls: NSView, radius: CGFloat = 16, inset: CGFloat = 10) -> NSGlassEffectView {
        let glass = NSGlassEffectView()
        glass.cornerRadius = radius
        glass.style = .regular
        if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
        glass.contentView = padded(controls, inset: inset)
        return glass
    }

    static func glassContainer(_ content: NSView) -> NSGlassEffectContainerView {
        let container = NSGlassEffectContainerView()
        // Batch nearby effects while preserving separate control groups at rest.
        container.spacing = 0
        container.contentView = content
        return container
    }

    static func section(_ content: NSView, inset: CGFloat = 16) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.borderWidth = 0
        box.borderColor = .separatorColor
        box.fillColor = NSColor.alternatingContentBackgroundColors[1]
        box.cornerRadius = 14
        box.contentViewMargins = .zero
        box.contentView = padded(content, inset: inset)
        return box
    }

    static func symbol(_ name: String, size: CGFloat = 20, color: NSColor = .secondaryLabelColor) -> NSImageView {
        let image = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        image.contentTintColor = color
        image.widthAnchor.constraint(equalToConstant: size + 4).isActive = true
        image.heightAnchor.constraint(equalToConstant: size + 4).isActive = true
        return image
    }

    static func row(_ leading: NSView, _ trailing: NSView) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let result = stack([leading, spacer, trailing], axis: .horizontal, spacing: 16)
        result.setHuggingPriority(.defaultLow, for: .horizontal)
        return result
    }

    static func groupedRows(_ rows: [NSView]) -> NSBox {
        var arranged: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = NSBox()
                separator.boxType = .separator
                arranged.append(separator)
            }
            arranged.append(row)
        }
        let content = stack(arranged, spacing: 12)
        arranged.forEach { $0.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        return section(content)
    }

    static func toggleRow(_ title: String, subtitle: String? = nil, isOn: Bool,
                          action: @escaping (Bool) -> Void) -> NSView {
        var labels = [label(title)]
        if let subtitle { labels.append(label(subtitle, size: 11, color: .secondaryLabelColor)) }
        let control = ActionSwitch(isOn: isOn, action: action)
        control.setAccessibilityLabel(title)
        return row(stack(labels, spacing: 4), control)
    }

    static func settingsPage(_ title: String, subtitle: String, controls: [NSView]) -> NSView {
        let content = stack([label(title, size: 24, weight: .semibold),
                             label(subtitle, color: .secondaryLabelColor)] + controls, spacing: 18)
        for control in controls { control.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        let document = FlippedView()
        document.addSubview(content)
        pin(content, to: document, inset: 24)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        return scroll
    }

    static func error(_ error: Error, in window: NSWindow? = nil) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) }
        else { NSApp.activate(); alert.runModal() }
    }
}

@MainActor
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class ContentBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

@MainActor
private final class ActionSwitch: NSSwitch {
    private let handler: (Bool) -> Void

    init(isOn: Bool, action: @escaping (Bool) -> Void) {
        handler = action
        super.init(frame: .zero)
        state = isOn ? .on : .off
        target = self
        self.action = #selector(changed)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc private func changed() { handler(state == .on) }
}

@MainActor
final class ActionButton: NSButton {
    enum Style { case standard, glass, toolbar, accessoryBar }
    private var actionHandler: () -> Void

    init(_ title: String, symbol: String? = nil, symbolColor: NSColor? = nil,
         style: Style = .standard, action: @escaping () -> Void) {
        self.actionHandler = action
        super.init(frame: .zero)
        self.title = title
        cell?.wraps = false
        cell?.lineBreakMode = .byClipping
        setContentCompressionResistancePriority(.required, for: .horizontal)
        switch style {
        case .standard: bezelStyle = .automatic
        case .glass: bezelStyle = .glass
        case .toolbar:
            bezelStyle = .toolbar
            isBordered = true
            showsBorderOnlyWhileMouseInside = true
        case .accessoryBar:
            bezelStyle = .accessoryBarAction
            isBordered = true
            showsBorderOnlyWhileMouseInside = false
            font = .systemFont(ofSize: 13, weight: .medium)
            heightAnchor.constraint(equalToConstant: 32).isActive = true
        }
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            imagePosition = .imageLeading
            imageHugsTitle = true
            if style == .accessoryBar { symbolConfiguration = .init(pointSize: 15, weight: .medium) }
            if let symbolColor {
                let palette = NSImage.SymbolConfiguration(paletteColors: [symbolColor])
                symbolConfiguration = symbolConfiguration?.applying(palette) ?? palette
            }
        }
        target = self
        self.action = #selector(invoke)
        setAccessibilityLabel(title)
    }

    convenience init(icon title: String, symbol: String, symbolColor: NSColor? = nil,
                     style: Style = .toolbar, action: @escaping () -> Void) {
        self.init(title, symbol: symbol, symbolColor: symbolColor, style: style, action: action)
        imagePosition = .imageOnly
        toolTip = title
        widthAnchor.constraint(equalToConstant: style == .accessoryBar ? 40 : 32).isActive = true
        if style != .accessoryBar { heightAnchor.constraint(equalToConstant: 32).isActive = true }
    }

    convenience init(checkbox title: String, checked: Bool, action: @escaping (Bool) -> Void) {
        self.init(title, action: {})
        setButtonType(.switch)
        state = checked ? .on : .off
        actionHandler = { [weak self] in action(self?.state == .on) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc private func invoke() { actionHandler() }
}

struct AppError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
