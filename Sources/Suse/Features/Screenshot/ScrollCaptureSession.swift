import AppKit
import ScreenCaptureKit
import SuseCore

@MainActor
final class ScrollCaptureSession {
    private let region: CGRect
    private let displayID: CGDirectDisplayID
    private let input: AutomaticScrollInput
    private let clicks: ScrollCaptureClickMonitor
    private let engine: ScrollCaptureEngine
    private var panel: ScrollCapturePanel?
    private var outline: ScrollCaptureOutline?

    init(capture: ScreenCaptureService, region: CGRect, snapshot: ScreenSnapshot, content: SCShareableContent) {
        self.region = region
        displayID = snapshot.display.displayID
        let clicks = ScrollCaptureClickMonitor(region: region)
        self.clicks = clicks
        let input = AutomaticScrollInput(region: region, prepare: { clicks.start() })
        self.input = input
        let display = snapshot.display
        // Keep the frozen first frame's pixel grid for samples, retries, and the final capture.
        let pixelSize = CGSize(width: snapshot.image.width, height: snapshot.image.height)
        var currentContent = content
        engine = ScrollCaptureEngine(input: input, captureFrame: {
            try await capture.capture(region: region, display: display, pixelSize: pixelSize, content: currentContent)
        }, refreshContent: {
            currentContent = try await capture.content()
        })
        engine.onUpdate = { [weak self] state, message in
            guard let self else { return }
            panel?.update(state: state, message: message, automatic: engine.automatic)
            clicks.enabled = engine.automatic && state != .finishing
        }
        clicks.onStop = { [weak engine] in engine?.stopForClick() }
        clicks.onFinish = { [weak engine] in engine?.finish() }
        clicks.onUnavailable = { [weak engine] in engine?.inputUnavailable() }
        clicks.targetIsActive = { [weak input] in
            guard let input else { return false }
            return (try? input.validateTarget()) != nil
        }
        clicks.excludesPoint = { [weak self] point in
            guard let panel = self?.panel else { return false }
            return ScreenGeometry.quartzRect(fromAppKit: panel.frame, mainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height).contains(point)
        }
        input.pointIsBlocked = clicks.excludesPoint
    }

    func run(initialImage: CGImage, source: NSRunningApplication?, windowID: CGWindowID?) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        guard initialImage.height <= 30_000, initialImage.width <= 48_000_000 / max(1, initialImage.height) else {
            UI.error(AppError("选区过大，请缩小后重试。"))
            return nil
        }
        input.targetPID = source?.processIdentifier
        input.targetWindowID = windowID
        showControls()
        source?.activate()
        defer { closeControls() }
        let image = await engine.run(initialImage: initialImage)
        if image == nil, !engine.cancelled, !Task.isCancelled {
            UI.error(AppError("长图生成失败，可能是可用内存不足。"))
        }
        return image
    }

    private func showControls() {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) ?? NSScreen.main else { return }
        let selection = ScreenGeometry.quartzRect(fromAppKit: region, mainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height)
        let outline = ScrollCaptureOutline(selection: selection)
        outline.orderFrontRegardless()
        self.outline = outline
        let panel = ScrollCapturePanel(selectionRect: selection, visibleFrame: screen.visibleFrame,
                                       onPause: { [weak engine] in engine?.togglePause() },
                                       onCancel: { [weak self] in self?.cancel() },
                                       onFinish: { [weak engine] in engine?.finish() },
                                       onAutomatic: { [weak engine] in engine?.toggleAutomatic() })
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func closeControls() {
        clicks.stop()
        panel?.orderOut(nil)
        outline?.orderOut(nil)
        panel = nil
        outline = nil
    }

    func finish() { engine.finish() }

    func cancel() {
        engine.cancel()
        closeControls()
    }
}
