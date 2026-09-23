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
    private var panel: ScrollCapturePanel?
    private var outline: NSWindow?
    private var task: Task<Void, Never>?
    private var completion: CheckedContinuation<CGImage?, Never>?
    private var paused = false
    private var finishing = false
    private var finishRequested = false
    private var cancelled = false
    private var frameCount = 1

    init(capture: ScreenCaptureService, region: CGRect, display: SCDisplay, content: SCShareableContent) {
        self.capture = capture
        self.region = region
        self.display = display
        self.content = content
    }

    func run(initialImage: CGImage, source: NSRunningApplication?) async -> CGImage? {
        let initial = await stitcher.append(initialImage)
        guard !cancelled, !Task.isCancelled else { return nil }
        guard case .appended = initial else { UI.error(AppError("选区过大，请缩小后重试。")); return nil }
        if finishRequested { return await stitcher.makeImage() }
        return await withCheckedContinuation { continuation in
            completion = continuation
            showControls()
            showOutline()
            source?.activate()
            startSampling()
        }
    }

    private func startSampling() {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // Refresh after creating the HUD and on retry so controls remain excluded.
                content = try await capture.content()
                try Task.checkCancellation()
                await sampleUntilCancelled()
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, !finishing, !cancelled else { return }
                paused = true
                panel?.update(state: .retry, message: error.localizedDescription)
            }
        }
    }

    private func showControls() {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }) ?? NSScreen.main else { return }
        let selection = ScreenGeometry.quartzRect(fromAppKit: region, mainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height)
        let panel = ScrollCapturePanel(selectionRect: selection, visibleFrame: screen.visibleFrame,
                                       onPause: { [weak self] in self?.togglePause() },
                                       onCancel: { [weak self] in self?.cancel() },
                                       onFinish: { [weak self] in self?.finish() })
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func showOutline() {
        let frame = ScreenGeometry.quartzRect(fromAppKit: region, mainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height)
        let window = NSWindow(contentRect: frame.insetBy(dx: -2, dy: -2), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let border = NSView(frame: CGRect(origin: .zero, size: window.frame.size))
        border.wantsLayer = true
        border.layer?.borderColor = NSColor.controlAccentColor.cgColor
        border.layer?.borderWidth = 2
        window.contentView = border
        window.orderFrontRegardless()
        outline = window
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
                guard !paused else { continue }
                switch result {
                case .appended(let height, let frames):
                    frameCount = frames
                    panel?.update(state: .recording, message: "已拼接 \(frames) 帧 · 长图高度 \(height) px")
                case .unchanged: break
                case .rejected(let reason): panel?.update(state: .recording, message: reason)
                case .limitReached:
                    paused = true
                    panel?.update(state: .limitReached, message: "已达到 30,000 px / 48 MP 上限")
                }
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                paused = true
                panel?.update(state: .retry, message: "捕获暂停：\(error.localizedDescription)")
            }
        }
    }

    private func togglePause() {
        guard !finishing, !cancelled else { return }
        paused.toggle()
        panel?.update(state: paused ? .paused : .recording,
                      message: paused ? "已暂停 · \(frameCount) 帧" : "继续向下滚动 · 已记录 \(frameCount) 帧")
        if !paused { startSampling() }
    }

    func finish() {
        guard completion != nil else { finishRequested = true; return }
        guard !finishing else { return }
        finishing = true
        task?.cancel()
        panel?.update(state: .finishing, message: "正在生成长图…")
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
            guard !cancelled else { return }
            panel?.orderOut(nil)
            outline?.orderOut(nil)
            completion?.resume(returning: result)
            completion = nil
            if result == nil { UI.error(AppError("长图生成失败，可能是可用内存不足。")) }
        }
    }

    func cancel() {
        cancelled = true
        task?.cancel()
        panel?.orderOut(nil)
        outline?.orderOut(nil)
        completion?.resume(returning: nil)
        completion = nil
    }
}
