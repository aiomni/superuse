import AppKit
import ApplicationServices

@MainActor
final class AutomaticScrollInput {
    enum EnableError: LocalizedError, Equatable {
        case missingTarget, accessibilityDenied, clickMonitorUnavailable

        var errorDescription: String? {
            switch self {
            case .missingTarget:
                "未找到目标窗口，请重新框选窗口内容；也可手动滚动。"
            case .accessibilityDenied:
                "当前应用尚未获得辅助功能权限；请在系统设置中允许后重试，或手动滚动。"
            case .clickMonitorUnavailable:
                "无法监听选区点击，请重试自动滚动，或手动滚动后点“完成”。"
            }
        }
    }

    var targetPID: pid_t?
    var targetWindowID: CGWindowID?
    var pointIsBlocked: (CGPoint) -> Bool = { _ in false }
    private let region: CGRect
    private let hasAccess: () -> Bool
    private let requestAccess: () -> Bool
    private let frontmostPID: () -> pid_t?
    private let modifiers: () -> CGEventFlags
    private let targetIsVisible: @MainActor (pid_t, CGWindowID, CGPoint) -> Bool
    private let prepare: () -> Bool
    private let post: (CGEvent) -> Void

    init(region: CGRect, hasAccess: @escaping () -> Bool = { AXIsProcessTrusted() },
         requestAccess: @escaping () -> Bool = {
             // Use the documented key value: the SDK exposes the constant as a mutable C global.
             AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
         },
         frontmostPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
         modifiers: @escaping () -> CGEventFlags = { CGEventSource.flagsState(.combinedSessionState) },
         targetIsVisible: @escaping @MainActor (pid_t, CGWindowID, CGPoint) -> Bool = AutomaticScrollInput.targetIsVisible,
         prepare: @escaping () -> Bool = { true },
         post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.region = region
        self.hasAccess = hasAccess
        self.requestAccess = requestAccess
        self.frontmostPID = frontmostPID
        self.modifiers = modifiers
        self.targetIsVisible = targetIsVisible
        self.prepare = prepare
        self.post = post
    }

    func enable(prompt: Bool) throws(EnableError) {
        guard targetPID != nil, targetWindowID != nil else { throw .missingTarget }
        guard hasAccess() || (prompt && requestAccess()) else { throw .accessibilityDenied }
        guard prepare() else { throw .clickMonitorUnavailable }
    }

    func validateTarget() throws {
        guard hasAccess() else { throw EnableError.accessibilityDenied }
        guard let targetPID, frontmostPID() == targetPID else {
            throw AppError("目标应用已切换，自动滚动已暂停。请返回原窗口后继续。")
        }
        let point = CGPoint(x: region.midX, y: region.midY)
        guard let targetWindowID, targetIsVisible(targetPID, targetWindowID, point) else {
            throw AppError("原窗口已移动或被遮挡，自动滚动已暂停。请恢复窗口后继续。")
        }
    }

    /// Window-server routing is required for native scroll views. Validate the destination before posting.
    @discardableResult
    func scrollDown() throws -> Bool {
        try validateTarget()
        guard modifiers().intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else { return false }
        let point = CGPoint(x: region.midX, y: region.midY)
        guard !pointIsBlocked(point) else { throw AppError("控制面板挡住了滚动位置，请将面板移开后继续。") }
        let distance = Int32(max(1, min(160, floor(region.height / 4))))
        guard let event = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .privateState), units: .pixel,
                                  wheelCount: 1, wheel1: -distance, wheel2: 0, wheel3: 0) else {
            throw AppError("无法发送滚动操作，请切换为手动滚动。")
        }
        event.location = point
        event.flags = []
        post(event)
        return true
    }

    private static func targetIsVisible(pid: pid_t, windowID: CGWindowID, point: CGPoint) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for window in windows {
            guard let owner = window[kCGWindowOwnerPID as String] as? Int32,
                  owner != ownPID,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.contains(point) else { continue }
            return owner == pid && (window[kCGWindowNumber as String] as? UInt32) == windowID
        }
        return false
    }
}
