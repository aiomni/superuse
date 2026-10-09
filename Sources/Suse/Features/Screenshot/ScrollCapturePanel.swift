import AppKit

/// Nonactivating capture controls. Status changes never resize or reposition the panel.
@MainActor
final class ScrollCapturePanel: NSPanel {
    typealias CaptureState = ScrollCaptureState

    private let status = UI.label("", size: 12, weight: .medium)
    private let hint = UI.label("", size: 11, color: .secondaryLabelColor)
    private let pauseButton: ActionButton
    private let finishButton: ActionButton
    private let automaticButton: ActionButton

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(selectionRect: CGRect, visibleFrame: CGRect, onPause: @escaping () -> Void,
         onCancel: @escaping () -> Void, onFinish: @escaping () -> Void, onAutomatic: @escaping () -> Void = {}) {
        pauseButton = ActionButton("暂停", symbol: "pause", style: .accessoryBar, action: onPause)
        automaticButton = ActionButton("自动滚动", symbol: "arrow.down", style: .accessoryBar, action: onAutomatic)
        finishButton = ActionButton("完成", symbol: "checkmark", symbolColor: .systemGreen,
                                    style: .accessoryBar, action: onFinish)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "滚动截图"
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .screenSaver
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true

        pauseButton.setAccessibilityIdentifier("scroll-capture-pause")
        pauseButton.widthAnchor.constraint(equalToConstant: 80).isActive = true
        automaticButton.setAccessibilityIdentifier("scroll-capture-automatic")
        automaticButton.widthAnchor.constraint(equalToConstant: 104).isActive = true
        finishButton.setAccessibilityIdentifier("scroll-capture-finish")
        finishButton.toolTip = "完成滚动截图并返回编辑；也可再次按截图快捷键"
        let cancel = ActionButton(icon: "取消滚动截图", symbol: "xmark", symbolColor: .systemRed,
                                  style: .accessoryBar, action: onCancel)
        cancel.setAccessibilityIdentifier("scroll-capture-cancel")
        cancel.toolTip = "取消滚动截图，返回原图编辑"
        let actions = UI.stack([automaticButton, pauseButton, cancel, finishButton], axis: .horizontal, spacing: 8)
        let bar = UI.glassBar(actions, inset: 8)
        bar.setAccessibilityIdentifier("scroll-capture-actions")

        status.setAccessibilityIdentifier("scroll-capture-status")
        hint.setAccessibilityIdentifier("scroll-capture-hint")
        for label in [status, hint] {
            label.usesSingleLineMode = true
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.widthAnchor.constraint(equalToConstant: 320).isActive = true
        }
        let badge = NSBox()
        badge.boxType = .custom
        badge.titlePosition = .noTitle
        badge.borderWidth = 0
        badge.cornerRadius = 8
        badge.fillColor = .windowBackgroundColor
        badge.contentViewMargins = .zero
        badge.contentView = UI.padded(UI.stack([status, hint], spacing: 4), inset: 8)
        let content = UI.stack([badge, bar], spacing: 8)
        content.alignment = .trailing
        let root = UI.padded(content, inset: 4)
        contentView = root
        update(state: .recording, message: "已记录第 1 帧 · 停稳后自动拼接")
        setContentSize(root.fittingSize)
        setFrame(Self.placement(size: frame.size, selection: selectionRect, visibleFrame: visibleFrame), display: false)
    }

    func update(state: CaptureState, message: String, automatic: Bool = false) {
        status.stringValue = message
        status.toolTip = message
        pauseButton.isEnabled = state != .limitReached && state != .finishing
        finishButton.isEnabled = state != .finishing
        automaticButton.isEnabled = state != .limitReached && state != .finishing
        automaticButton.title = automatic ? "手动滚动" : "自动滚动"
        automaticButton.image = NSImage(systemSymbolName: automatic ? "hand.draw" : "arrow.down", accessibilityDescription: nil)
        automaticButton.toolTip = automatic ? "切换为手动滚动，保留已拼接内容" : "自动向下滚动并拼接，点击选区完成"
        automaticButton.setAccessibilityLabel("切换为\(automaticButton.title)")
        let title: String, symbol: String
        switch state {
        case .recording:
            title = "暂停"; symbol = "pause"
            hint.stringValue = automatic ? "点击选区或再按截图快捷键完成" : "缓慢向下滚动 · 再按截图快捷键完成"
        case .paused:
            title = "继续"; symbol = "play"
            hint.stringValue = automatic ? "点击选区完成，或继续自动滚动" : "继续后恢复捕获，已拼接内容会保留"
        case .retry:
            title = "重试"; symbol = "arrow.clockwise"
            hint.stringValue = automatic ? "返回原窗口重试，或点击选区完成" : "重试捕获，或完成并保留已有长图"
        case .limitReached:
            title = "暂停"; symbol = "pause"
            hint.stringValue = automatic ? "点击选区完成，保留已拼接内容" : "请完成截图，保留已拼接的内容"
        case .finishing:
            title = "暂停"; symbol = "pause"
            hint.stringValue = "请稍候，完成后返回截图编辑"
        }
        pauseButton.title = title
        pauseButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        pauseButton.setAccessibilityLabel("\(title)滚动捕获")
        pauseButton.toolTip = "\(title)滚动捕获"
    }

    /// AppKit screen coordinates: prefer outside the selection, aligned with its right edge.
    static func placement(size: CGSize, selection: CGRect, visibleFrame: CGRect) -> CGRect {
        let margin: CGFloat = 12
        let available = visibleFrame.insetBy(dx: margin, dy: margin)
        let x = max(available.minX, min(selection.maxX - size.width, available.maxX - size.width))
        for y in [selection.minY - margin - size.height, selection.maxY + margin] {
            let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            if available.contains(frame) { return frame }
        }
        let y = max(available.minY, min(selection.maxY - size.height, available.maxY - size.height))
        for x in [selection.maxX + margin, selection.minX - margin - size.width] {
            let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            if available.contains(frame) { return frame }
        }
        return CGRect(origin: CGPoint(x: x, y: available.minY), size: size)
    }
}
