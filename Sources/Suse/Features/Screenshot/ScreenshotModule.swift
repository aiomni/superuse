import AppKit
import ScreenCaptureKit
import SuseCore

@MainActor
final class ScreenshotModule: FeatureModule {
    let id = "screenshot"
    let title = "截图"
    let symbol = "viewfinder"
    let summary = "一个快捷键，自动识别屏幕和窗口，拖动选择区域。"
    private let settings: SettingsStore
    private let capture = ScreenCaptureService()
    private let selector = SelectionController()
    private var captureTask: Task<Void, Never>?
    private var scrollSession: ScrollCaptureSession?

    init(settings: SettingsStore) { self.settings = settings }

    var commands: [AppCommand] {
        // Retain the previous region command ID so a user's shortcut or disabled state survives.
        [AppCommand(id: "screenshot.region", title: "截图", group: title, symbol: symbol,
                    defaultShortcut: Shortcut(keyCode: 0, modifiers: [.shift, .command])) { [weak self] in
            self?.begin()
        }]
    }

    func start() { }
    func stop() {
        captureTask?.cancel()
        selector.cancel()
        scrollSession?.cancel()
    }

    private func begin() {
        if let scrollSession { scrollSession.finish(); return }
        if captureTask != nil { stop(); return }
        let source = NSWorkspace.shared.frontmostApplication
        captureTask = Task { [weak self] in
            guard let self else { return }
            defer {
                selector.close()
                captureTask = nil
                scrollSession = nil
            }
            do {
                // Allow a menu invocation to dismiss before freezing the displays.
                try await Task.sleep(for: .milliseconds(180))
                let content = try await capture.content()
                try Task.checkCancellation()
                let windows = capture.orderedWindows(in: content)
                let candidates = windows.map { CaptureWindow(id: $0.windowID, frame: $0.frame) }
                var snapshots: [ScreenSnapshot] = []
                for display in content.displays {
                    snapshots.append(try await capture.snapshot(display: display, content: content))
                    try Task.checkCancellation()
                }
                guard !snapshots.isEmpty else { throw AppError("未找到可截图的屏幕。") }
                while !Task.isCancelled {
                    guard let selection = await selector.select(snapshots: snapshots, windows: candidates) else { return }
                    try Task.checkCancellation()
                    let shouldReselect = try await review(selection, content: content, windows: windows, source: source)
                    if !shouldReselect { return }
                }
            } catch is CancellationError { }
            catch {
                selector.close()
                UI.error(error)
            }
        }
    }

    /// Returns true only when the user explicitly chooses to select another area.
    private func review(_ selection: CaptureSelection, content: SCShareableContent,
                        windows: [SCWindow], source: NSRunningApplication?) async throws -> Bool {
        var image = try selection.snapshot.crop(selection.target.rect)
        var allowsScrolling = true
        var copyAutomatically = settings.defaults.bool(forKey: "screenshot.copyAfterCapture")
        while !Task.isCancelled {
            let action = await selector.review(image: image, selection: selection, allowsScrolling: allowsScrolling,
                                               copyAutomatically: copyAutomatically)
            try Task.checkCancellation()
            switch action {
            case .done: return false
            case .reselect: return true
            case .scroll:
                copyAutomatically = false
                selector.suspend()
                let session = ScrollCaptureSession(capture: capture, region: selection.target.rect,
                                                   display: selection.snapshot.display, content: content)
                scrollSession = session
                let center = CGPoint(x: selection.target.rect.midX, y: selection.target.rect.midY)
                let window: SCWindow?
                if case .window(let id) = selection.target.kind { window = windows.first { $0.windowID == id } }
                else { window = windows.first { $0.frame.contains(center) } }
                let owner = window?.owningApplication
                let target = owner.flatMap { NSRunningApplication(processIdentifier: $0.processID) } ?? source
                if let stitched = await session.run(initialImage: image, source: target) {
                    image = stitched
                    allowsScrolling = false
                    copyAutomatically = settings.defaults.bool(forKey: "screenshot.copyAfterCapture")
                }
                scrollSession = nil
                try Task.checkCancellation()
            }
        }
        return false
    }

    func makeSettingsView() -> NSView {
        UI.settingsPage("截图", subtitle: "自动框选、原位编辑，一个快捷键完成。", controls: [
            UI.groupedRows([UI.toggleRow("自动复制截图", subtitle: "确认选区后复制原图。", isOn: settings.defaults.bool(forKey: "screenshot.copyAfterCapture")) { [weak self] enabled in
                self?.settings.defaults.set(enabled, forKey: "screenshot.copyAfterCapture")
            }]),
            UI.section(UI.stack([
                UI.label("单击确认，拖动框选", size: 16, weight: .semibold),
                UI.label("按截图快捷键后，鼠标在窗口上自动框选窗口，在桌面或全屏应用上框选当前屏幕。单击确认；按住拖动始终选择区域。确认后画面保持定格，可进入滚动截图、原位编辑、复制或保存。Esc 退出。", color: .secondaryLabelColor),
            ])),
            UI.section(UI.stack([
                UI.label("编辑与滚动", size: 14, weight: .semibold),
                UI.label("标注支持画笔、箭头、矩形、椭圆、文字、实心遮挡和马赛克打码。选中打码后拖动框选，细／中／粗调整颗粒大小。⌘Z 撤销，⇧⌘Z 重做，Esc 退出截图。Enter 复制并完成，⌘S 保存 PNG。", size: 12, color: .secondaryLabelColor),
                UI.label("滚动截图时避开固定页眉 / 侧栏，缓慢向下滚动，每次保留至少 1/4 重叠。点击完成或再次按截图快捷键，返回原位预览。", size: 12, color: .secondaryLabelColor),
            ], spacing: 10)),
            UI.label("区域选择位于一块显示器内。长图上限为 30,000 px 高或 48 MP。", size: 11, color: .secondaryLabelColor),
        ])
    }
}
