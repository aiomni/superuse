import AppKit
import ApplicationServices

@MainActor
final class PasteService {
    func paste(to application: NSRunningApplication?) async throws {
        guard let application, !application.isTerminated,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw AppError("内容已复制。请切换到目标输入框，按 ⌘V 粘贴。")
        }
        guard AXIsProcessTrusted() else {
            // The SDK exports this immutable key as a mutable C global; use its documented value.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            throw AppError("内容已复制。开启 Suse 的辅助功能权限后，即可直接粘贴到原来的输入框。")
        }
        application.activate()
        // Restore focus, then wait for the shortcut modifiers to be released.
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(50))
            let modifiers = CGEventSource.flagsState(.combinedSessionState)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
               modifiers.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty {
                guard let source = CGEventSource(stateID: .combinedSessionState),
                      let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
                    throw AppError("无法发送粘贴按键。内容已复制，可用 ⌘V 粘贴。")
                }
                down.flags = .maskCommand
                up.flags = .maskCommand
                down.postToPid(application.processIdentifier)
                up.postToPid(application.processIdentifier)
                return
            }
        }
        throw AppError("未能恢复目标应用的焦点。内容已复制，请手动粘贴。")
    }
}
