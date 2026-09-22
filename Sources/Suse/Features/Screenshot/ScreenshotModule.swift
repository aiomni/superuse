import AppKit
import ScreenCaptureKit
import SuseCore

@MainActor
final class ScreenshotModule: FeatureModule {
    let id = "screenshot"
    let title = "截图"
    let symbol = "viewfinder"
    let summary = "捕获屏幕的一部分，再把重点标出来。"
    private let settings: SettingsStore
    private let capture = ScreenCaptureService()
    private let selector = SelectionController()
    private var captureTask: Task<Void, Never>?
    private var editors: [UUID: AnnotationWindowController] = [:]

    enum Mode { case fullScreen, region, window }

    init(settings: SettingsStore) { self.settings = settings }

    var commands: [AppCommand] {
        [command("fullScreen", title: "全屏截图", symbol: "rectangle.inset.filled", key: 18, mode: .fullScreen),
         command("region", title: "区域截图", symbol: "crop", key: 19, mode: .region),
         command("window", title: "窗口截图", symbol: "macwindow", key: 20, mode: .window)]
    }

    private func command(_ id: String, title: String, symbol: String, key: UInt32, mode: Mode) -> AppCommand {
        AppCommand(id: "screenshot.\(id)", title: title, group: self.title, symbol: symbol,
                   defaultShortcut: Shortcut(keyCode: key)) { [weak self] in self?.begin(mode) }
    }

    func start() { }
    func stop() { captureTask?.cancel(); selector.cancel() }

    private func begin(_ mode: Mode) {
        if captureTask != nil { captureTask?.cancel(); selector.cancel(); return }
        // Let a menu click finish dismissing its menu before ScreenCaptureKit samples it.
        captureTask = Task { [weak self] in
            guard let self else { return }
            defer { captureTask = nil }
            do {
                try await Task.sleep(for: .milliseconds(180))
                let content = try await capture.content()
                try Task.checkCancellation()
                let image: CGImage
                if mode == .fullScreen {
                    let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
                    let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                    guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
                        throw AppError("未找到可截图的屏幕。")
                    }
                    image = try await capture.snapshot(display: display, content: content).image
                } else {
                    var snapshots: [ScreenSnapshot] = []
                    for display in content.displays {
                        snapshots.append(try await capture.snapshot(display: display, content: content))
                        try Task.checkCancellation()
                    }
                    guard let selection = await selector.select(snapshots: snapshots, windows: capture.orderedWindows(in: content),
                                                                 mode: mode == .window ? .window : .region) else { return }
                    try Task.checkCancellation()
                    switch selection {
                    case .region(let rect, let snapshot): image = try snapshot.crop(rect)
                    case .window(let window): image = try await capture.capture(window: window)
                    }
                }
                try Task.checkCancellation()
                openEditor(image)
            } catch is CancellationError { }
            catch { UI.error(error) }
        }
    }

    func openEditor(_ image: CGImage) {
        let id = UUID()
        let editor = AnnotationWindowController(image: image)
        editor.onClose = { [weak self] in self?.editors.removeValue(forKey: id) }
        editors[id] = editor
        editor.show()
        if settings.defaults.bool(forKey: "screenshot.copyAfterCapture") { editor.copyImage() }
    }

    func makeSettingsView() -> NSView {
        UI.settingsPage("截图", subtitle: "截取、标注、复制，一次完成。", controls: [
            ActionButton(checkbox: "截图完成后自动复制原图", checked: settings.defaults.bool(forKey: "screenshot.copyAfterCapture")) { [weak self] enabled in
                self?.settings.defaults.set(enabled, forKey: "screenshot.copyAfterCapture")
            },
            UI.glass(UI.stack([
                UI.label("区域和窗口自由切换", size: 16, weight: .semibold),
                UI.label("全屏截图捕获鼠标所在的显示器。区域截图时拖动框选，按空格切换窗口模式，悬停自动识别窗口，点击确认；Esc 取消。每次区域选择位于一块显示器内。", color: .secondaryLabelColor),
            ])),
            UI.label("标注支持画笔、箭头、矩形、椭圆、文字和不透明遮挡，可撤销 / 重做。使用 ⇧⌘C 复制标注结果，⌘S 保存 PNG。", size: 12, color: .secondaryLabelColor),
        ])
    }
}
