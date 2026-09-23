import AppKit
import Testing
@testable import Suse

@Suite(.serialized)
@MainActor
struct ScrollCapturePanelTests {
    @Test func statusChangesKeepCompactControlsAnchoredAcrossAppearances() throws {
        let panel = makePanel()
        defer { panel.close() }
        let content = try #require(panel.contentView)
        let views = descendants(content)
        let bar = try #require(views.first { $0 is NSGlassEffectView })
        let status = try label("scroll-capture-status", in: content)
        let pause = try button("scroll-capture-pause", in: content)
        let finish = try button("scroll-capture-finish", in: content)
        let cancel = try button("scroll-capture-cancel", in: content)
        let buttons = [pause, cancel, finish]
        panel.setFrameOrigin(CGPoint(x: 60, y: 80))
        content.layoutSubtreeIfNeeded()
        let originalFrame = panel.frame
        let barFrame = content.convert(bar.bounds, from: bar)
        let buttonFrames = buttons.map { content.convert($0.bounds, from: $0) }
        #expect(panel.frame.width < 400 && panel.frame.height < 120)
        #expect(!status.isDescendant(of: bar))
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(panel.styleMask.contains(.nonactivatingPanel))

        let states: [(ScrollCapturePanel.CaptureState, String, String, Bool, Bool)] = [
            (.recording, "已拼接 12 帧 · 长图高度 8400 px", "暂停", true, true),
            (.paused, "已暂停 · 12 帧", "继续", true, true),
            (.retry, String(repeating: "捕获暂停：测试错误说明。", count: 15), "重试", true, true),
            (.limitReached, "已达到 30,000 px / 48 MP 上限", "暂停", false, true),
            (.finishing, "正在生成长图…", "暂停", false, false),
        ]
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua),
                                   ("contrast-light", .accessibilityHighContrastAqua),
                                   ("contrast-dark", .accessibilityHighContrastDarkAqua)] {
            panel.appearance = NSAppearance(named: appearance)
            for (state, message, title, canPause, canFinish) in states {
                panel.update(state: state, message: message)
                content.layoutSubtreeIfNeeded()
                #expect(panel.frame == originalFrame)
                #expect(content.convert(bar.bounds, from: bar) == barFrame)
                #expect(buttons.map { content.convert($0.bounds, from: $0) } == buttonFrames)
                #expect(pause.title == title && pause.isEnabled == canPause)
                #expect(finish.isEnabled == canFinish && cancel.isEnabled)
                #expect(status.stringValue == message && status.toolTip == message)
                #expect(pause.accessibilityLabel() == "\(title)滚动捕获")
                #expect(content.bounds.contains(content.convert(status.bounds, from: status)))
                for (index, button) in buttons.enumerated() {
                    let frame = content.convert(button.bounds, from: button)
                    #expect(barFrame.contains(frame))
                    #expect(abs(frame.midY - buttonFrames[0].midY) < 1)
                    if index > 0 { #expect(!frame.intersects(buttonFrames[index - 1])) }
                }
            }
            panel.update(state: .recording, message: "已拼接 12 帧 · 长图高度 8400 px")
            try render(panel, name: name)
        }
    }

    @Test func pauseFinishAndCancelDispatchOnlyEnabledActions() throws {
        var pauseCount = 0, finishCount = 0, cancelCount = 0
        let panel = makePanel(onPause: { pauseCount += 1 }, onCancel: { cancelCount += 1 }, onFinish: { finishCount += 1 })
        defer { panel.close() }
        let content = try #require(panel.contentView)
        let pause = try button("scroll-capture-pause", in: content)
        let finish = try button("scroll-capture-finish", in: content)
        let cancel = try button("scroll-capture-cancel", in: content)
        for state in [ScrollCapturePanel.CaptureState.recording, .paused, .retry] {
            panel.update(state: state, message: "测试状态")
            pause.performClick(nil)
        }
        #expect(pauseCount == 3)
        panel.update(state: .limitReached, message: "达到上限")
        pause.performClick(nil)
        finish.performClick(nil)
        #expect(pauseCount == 3 && finishCount == 1)
        panel.update(state: .finishing, message: "正在生成长图…")
        pause.performClick(nil)
        finish.performClick(nil)
        cancel.performClick(nil)
        #expect(pauseCount == 3 && finishCount == 1 && cancelCount == 1)
    }

    @Test func initialPlacementPrefersOutsideSelectionAndHandlesNegativeDisplayOrigins() {
        let size = CGSize(width: 344, height: 104)
        for origin in [CGPoint.zero, CGPoint(x: -1200, y: -800)] {
            let screen = CGRect(origin: origin, size: CGSize(width: 1200, height: 800))
            for selection in [CGRect(x: 260, y: 250, width: 600, height: 320),
                              CGRect(x: 0, y: 0, width: 600, height: 600),
                              CGRect(x: 1170, y: 770, width: 30, height: 30),
                              CGRect(x: 400, y: 0, width: 400, height: 800),
                              CGRect(x: 0, y: 0, width: 1200, height: 800)] {
                let region = selection.offsetBy(dx: origin.x, dy: origin.y)
                let frame = ScrollCapturePanel.placement(size: size, selection: region, visibleFrame: screen)
                #expect(screen.insetBy(dx: 12, dy: 12).contains(frame))
                if selection.size != screen.size { #expect(!frame.intersects(region)) }
            }
        }
    }

    private func makePanel(onPause: @escaping () -> Void = {}, onCancel: @escaping () -> Void = {},
                           onFinish: @escaping () -> Void = {}) -> ScrollCapturePanel {
        _ = NSApplication.shared
        return ScrollCapturePanel(selectionRect: CGRect(x: 260, y: 250, width: 600, height: 320),
                                  visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                                  onPause: onPause, onCancel: onCancel, onFinish: onFinish)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func label(_ identifier: String, in view: NSView) throws -> NSTextField {
        try #require(descendants(view).first { $0.accessibilityIdentifier() == identifier } as? NSTextField)
    }

    private func button(_ identifier: String, in view: NSView) throws -> NSButton {
        try #require(descendants(view).first { $0.accessibilityIdentifier() == identifier } as? NSButton)
    }

    private func render(_ panel: NSPanel, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SUSE_UI_PREVIEW_DIRECTORY"] else { return }
        let content = try #require(panel.contentView)
        content.layoutSubtreeIfNeeded()
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            content.cacheDisplay(in: content.bounds, to: bitmap)
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output.appending(path: "scroll-controls-\(name).png"))
    }
}
