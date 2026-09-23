import AppKit
import SuseCore

@MainActor
final class ClipboardRetentionSettingsView: NSView {
    typealias Confirmation = @MainActor (ClipboardRetentionPlan, NSWindow?) async -> Bool
    private let store: ClipboardStore
    private let confirm: Confirmation
    private let input = NSTextField()
    private let feedback = UI.label("置顶记录额外保留，超出数量的普通历史会自动清理。", size: 11, color: .secondaryLabelColor)
    private lazy var applyButton = ActionButton("应用") { [weak self] in self?.beginApply() }
    private var applying = false

    init(store: ClipboardStore, confirm: Confirmation? = nil) {
        self.store = store
        self.confirm = confirm ?? Self.confirmDeletion
        super.init(frame: .zero)
        input.stringValue = String(store.countLimit)
        input.placeholderString = String(ClipboardRetention.defaultLimit)
        input.setAccessibilityLabel("普通历史保留数量")
        input.widthAnchor.constraint(equalToConstant: 120).isActive = true
        input.target = self
        input.action = #selector(beginApply)
        let controls = UI.stack([input, UI.label("条"), applyButton], axis: .horizontal, spacing: 8)
        let row = UI.row(UI.label("普通历史保留数量"), controls)
        let content = UI.stack([row, feedback], spacing: 8)
        row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        feedback.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        addSubview(content)
        UI.pin(content, to: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @objc private func beginApply() { Task { await apply() } }

    func apply() async {
        guard !applying else { return }
        guard let limit = ClipboardRetention.parseLimit(input.stringValue) else {
            feedback.stringValue = "请输入有效的正整数。"
            feedback.textColor = .systemRed
            return
        }
        applying = true
        input.isEnabled = false
        applyButton.isEnabled = false
        defer { applying = false; input.isEnabled = true; applyButton.isEnabled = true }
        do {
            var plan = try await store.retentionPlan(limit: limit)
            while true {
                if plan.removedCount > 0, !(await confirm(plan, window)) {
                    input.stringValue = String(store.countLimit)
                    feedback.stringValue = "已取消，保留数量和历史数据未更改。"
                    feedback.textColor = .secondaryLabelColor
                    return
                }
                if let revised = try await store.applyRetention(plan) {
                    plan = revised
                    continue
                }
                input.stringValue = String(limit)
                feedback.stringValue = "已设置为 \(limit) 条普通历史，置顶记录额外保留。"
                feedback.textColor = .secondaryLabelColor
                return
            }
        } catch {
            input.stringValue = String(store.countLimit)
            feedback.stringValue = "未能更改保留数量：\(error.localizedDescription)"
            feedback.textColor = .systemRed
        }
    }

    private static func confirmDeletion(_ plan: ClipboardRetentionPlan, in window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除较早的历史记录？"
        alert.informativeText = "将保留全部 \(plan.pinnedCount) 条置顶和最新 \(plan.retainedOrdinaryCount) 条普通记录，删除 \(plan.removedCount) 条历史数据。此操作无法撤销。"
        alert.addButton(withTitle: "删除并应用")
        alert.addButton(withTitle: "取消")
        if let window {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
            }
        }
        return alert.runModal() == .alertFirstButtonReturn
    }
}
