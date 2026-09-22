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

    static func glass(_ content: NSView, radius: CGFloat = 20, inset: CGFloat = 20) -> NSGlassEffectView {
        let wrapper = NSView()
        wrapper.addSubview(content)
        pin(content, to: wrapper, inset: inset)
        let glass = NSGlassEffectView()
        glass.cornerRadius = radius
        glass.style = .regular
        glass.contentView = wrapper
        return glass
    }

    static func settingsPage(_ title: String, subtitle: String, controls: [NSView]) -> NSView {
        let content = stack([label(title, size: 24, weight: .semibold),
                             label(subtitle, color: .secondaryLabelColor)] + controls, spacing: 20)
        let view = NSView()
        view.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            content.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
        ])
        return view
    }

    static func error(_ error: Error, in window: NSWindow? = nil) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) }
        else { NSApp.activate(); alert.runModal() }
    }
}

@MainActor
final class ActionButton: NSButton {
    private var actionHandler: () -> Void

    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.actionHandler = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            imagePosition = .imageLeading
        }
        target = self
        self.action = #selector(invoke)
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
