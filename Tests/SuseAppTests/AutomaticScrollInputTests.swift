import AppKit
import Testing
@testable import Suse

@Suite(.serialized)
@MainActor
struct AutomaticScrollInputTests {
    @Test func inputScrollsAtSelectedQuartzPositionWithoutModifiers() throws {
        var events: [CGEvent] = []
        let region = CGRect(x: -900, y: -600, width: 400, height: 320)
        let input = AutomaticScrollInput(region: region, hasAccess: { true }, requestAccess: { Issue.record("Unexpected prompt"); return false },
                                         frontmostPID: { 42 }, modifiers: { [] }, targetIsVisible: { pid, window, _ in
            #expect(pid == 42 && window == 84)
            return true
        }, post: { events.append($0) })
        input.targetPID = 42
        input.targetWindowID = 84
        try input.enable(prompt: true)
        #expect(try input.scrollDown())
        let event = try #require(events.first)
        #expect(event.type == .scrollWheel)
        #expect(event.location == CGPoint(x: -700, y: -440))
        #expect(event.flags.isEmpty)
        #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -80)
        #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 0)
    }

    @Test func deniedRevokedAndChangedFocusNeverPostInput() throws {
        var access = false
        var frontmost: pid_t? = 42
        var requests = 0
        var flags: CGEventFlags = []
        var posts = 0
        let visibility = Visibility()
        let input = AutomaticScrollInput(region: CGRect(x: 0, y: 0, width: 400, height: 300), hasAccess: { access },
                                         requestAccess: { requests += 1; return false }, frontmostPID: { frontmost },
                                         modifiers: { flags }, targetIsVisible: { _, _, _ in visibility.isVisible }, post: { _ in posts += 1 })
        #expect(throws: AutomaticScrollInput.EnableError.missingTarget) { try input.enable(prompt: true) }
        #expect(requests == 0)
        input.targetPID = 42
        input.targetWindowID = 84
        #expect(throws: AutomaticScrollInput.EnableError.accessibilityDenied) { try input.enable(prompt: false) }
        #expect(requests == 0)
        #expect(throws: AutomaticScrollInput.EnableError.accessibilityDenied) { try input.enable(prompt: true) }
        #expect(requests == 1)
        #expect(throws: AutomaticScrollInput.EnableError.accessibilityDenied) { try input.scrollDown() }
        access = true
        try input.enable(prompt: true)
        #expect(requests == 1)
        frontmost = 43
        #expect(throws: AppError.self) { try input.scrollDown() }
        frontmost = 42
        flags = [.maskCommand, .maskShift]
        #expect(try !input.scrollDown())
        flags = []
        visibility.isVisible = false
        #expect(throws: AppError.self) { try input.scrollDown() }
        visibility.isVisible = true
        input.pointIsBlocked = { _ in true }
        #expect(throws: AppError.self) { try input.scrollDown() }
        input.pointIsBlocked = { _ in false }
        #expect(try input.scrollDown())
        access = false
        #expect(throws: AutomaticScrollInput.EnableError.accessibilityDenied) { try input.scrollDown() }
        #expect(posts == 1)
    }

    @Test func grantedAccessDoesNotMisreportMissingTargetOrClickMonitorFailure() throws {
        var requests = 0, preparations = 0, posts = 0
        var monitorReady = false
        let input = AutomaticScrollInput(region: CGRect(x: 0, y: 0, width: 400, height: 300), hasAccess: { true },
                                         requestAccess: { requests += 1; return false }, frontmostPID: { 42 },
                                         modifiers: { [] }, targetIsVisible: { _, _, _ in true }, prepare: {
            preparations += 1
            return monitorReady
        }, post: { _ in posts += 1 })
        input.targetWindowID = 84
        #expect(throws: AutomaticScrollInput.EnableError.missingTarget) { try input.enable(prompt: true) }
        input.targetPID = 42
        input.targetWindowID = nil
        #expect(throws: AutomaticScrollInput.EnableError.missingTarget) { try input.enable(prompt: true) }
        #expect(preparations == 0)
        input.targetWindowID = 84
        #expect(throws: AutomaticScrollInput.EnableError.clickMonitorUnavailable) { try input.enable(prompt: true) }
        #expect(requests == 0 && preparations == 1 && posts == 0)
        monitorReady = true
        try input.enable(prompt: true)
        #expect(try input.scrollDown())
        #expect(requests == 0 && preparations == 2 && posts == 1)
    }

    @Test func finishingClickIsConsumedButControlsOutsideClicksAndManualInputPassThrough() {
        _ = NSApplication.shared
        var stops = 0, finishes = 0, unavailable = 0
        let region = CGRect(x: -900, y: -600, width: 400, height: 300)
        let panel = ScrollCaptureOutline(selection: region)
        defer { panel.close() }
        #expect(!panel.canBecomeKey && !panel.canBecomeMain && panel.ignoresMouseEvents)
        let monitor = ScrollCaptureClickMonitor(region: region)
        let center = CGPoint(x: region.midX, y: region.midY)
        monitor.onStop = { [weak monitor] in stops += 1; monitor?.enabled = false }
        monitor.onFinish = { finishes += 1 }
        monitor.onUnavailable = { unavailable += 1 }
        #expect(!monitor.consume(type: .leftMouseDown, location: center))
        monitor.enabled = true
        #expect(!monitor.consume(type: .leftMouseDown, location: .zero))
        #expect(!monitor.consume(type: .scrollWheel, location: center))
        #expect(!monitor.consume(type: .rightMouseDown, location: center))
        monitor.excludesPoint = { _ in true }
        #expect(!monitor.consume(type: .leftMouseDown, location: center))
        monitor.excludesPoint = { _ in false }
        #expect(monitor.consume(type: .leftMouseDown, location: center))
        #expect(stops == 1 && finishes == 0)
        // Finish after releasing outside the region, even though mouse-down disabled new click interception.
        #expect(monitor.consume(type: .leftMouseUp, location: .zero))
        #expect(stops == 1 && finishes == 1)
        #expect(!monitor.consume(type: .leftMouseUp, location: center))
        monitor.enabled = true
        monitor.targetIsActive = { false }
        #expect(!monitor.consume(type: .leftMouseDown, location: center))
        #expect(unavailable == 1 && !monitor.enabled)
        monitor.stop()
        monitor.stop()
    }

    @MainActor
    private final class Visibility { var isVisible = true }
}
