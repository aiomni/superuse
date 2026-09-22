import AppKit
import ScreenCaptureKit
import SuseCore

@MainActor
final class ScrollCaptureSession {
    private let capture: ScreenCaptureService
    private let stitcher = ScrollStitcher()
    private let region: CGRect
    private let display: SCDisplay
    private var content: SCShareableContent
    private var panel: NSPanel?
    private var task: Task<Void, Never>?
    private var completion: CheckedContinuation<CGImage?, Never>?
    private var paused = false
    private var finishing = false
    private var cancelled = false
    private var frameCount = 1
    private let status = UI.label("准备捕获…", size: 12, color: .secondaryLabelColor)
    private var pauseButton: ActionButton?

    init(capture: ScreenCaptureService, region: CGRect, display: SCDisplay, content: SCShareableContent) {
        self.capture = capture
        self.region = region
        self.display = display
        self.content = content
    }

    func run(initialImage: CGImage, source: NSRunningApplication?) async -> CGImage? {
        let initial = await stitcher.append(initialImage)
        guard case .appended = initial else { UI.error(AppError("选区过大，请缩小后重试。")); return nil }
        return await withCheckedContinuation { continuation in
            completion = continuation
            showControls()
            source?.activate()
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    // Refresh after creating the HUD, so even a previously hidden Suse is in the
                    // application exclusion list. Otherwise its new controls could enter a frame.
                    content = try await capture.content()
                    try Task.checkCancellation()
                    await sampleUntilCancelled()
                } catch is CancellationError { }
                catch {
                    paused = true
                    status.stringValue = error.localizedDescription
                }
            }
        }
    }

    private func showControls() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 145),
                            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        let pause = ActionButton("暂停") { [weak self] in self?.togglePause() }
        pauseButton = pause
        let controls = UI.stack([
            UI.label("缓慢向下滚动，停稳后自动拼接", size: 16, weight: .semibold), status,
            UI.stack([pause,
                      ActionButton("取消") { [weak self] in self?.cancel() },
                      ActionButton("完成截图", symbol: "checkmark") { [weak self] in self?.finish() }], axis: .horizontal),
        ], spacing: 12)
        panel.contentView = UI.glass(controls, inset: 18)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - 260, y: screen.visibleFrame.minY + 24))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        status.stringValue = "已记录第 1 帧 · 再按滚动截图快捷键完成"
    }

    private func sampleUntilCancelled() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(400))
                guard !paused else { continue }
                let image = try await capture.capture(region: region, display: display, content: content)
                try Task.checkCancellation()
                guard !paused else { continue }
                let result = await stitcher.ingest(image)
                try Task.checkCancellation()
                switch result {
                case .appended(let height, let frames):
                    frameCount = frames
                    status.stringValue = "已拼接 \(frames) 帧 · 长图高度 \(height) px"
                case .unchanged: break
                case .rejected(let reason): status.stringValue = reason
                case .limitReached:
                    paused = true
                    pauseButton?.isEnabled = false
                    status.stringValue = "已达到 30,000 px / 48 MP 上限，请完成截图。"
                }
            } catch is CancellationError { return }
            catch {
                paused = true
                pauseButton?.title = "重试"
                status.stringValue = "捕获暂停：\(error.localizedDescription)"
            }
        }
    }

    private func togglePause() {
        paused.toggle()
        pauseButton?.title = paused ? "继续" : "暂停"
        status.stringValue = paused ? "已暂停 · \(frameCount) 帧" : "继续向下滚动"
    }

    func finish() {
        guard !finishing else { return }
        finishing = true
        task?.cancel()
        status.stringValue = "正在生成长图…"
        Task { [weak self] in
            guard let self else { return }
            await task?.value
            guard !cancelled else { return }
            // Include the last stopped viewport even when Finish was clicked before the next poll.
            if !paused {
                do {
                    let first = try await capture.capture(region: region, display: display, content: content)
                    _ = await stitcher.ingest(first)
                    try await Task.sleep(for: .milliseconds(180))
                    guard !cancelled else { return }
                    let second = try await capture.capture(region: region, display: display, content: content)
                    _ = await stitcher.ingest(second)
                } catch { /* Previously accepted strips remain a valid result. */ }
            }
            guard !cancelled else { return }
            let result = await stitcher.makeImage()
            panel?.orderOut(nil)
            completion?.resume(returning: result)
            completion = nil
            if result == nil { UI.error(AppError("长图生成失败，可能是可用内存不足。")) }
        }
    }

    func cancel() {
        cancelled = true
        task?.cancel()
        panel?.orderOut(nil)
        completion?.resume(returning: nil)
        completion = nil
    }
}
