import CoreGraphics
import Testing
@testable import SuseCore

struct CaptureSelectionTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let window = CaptureWindow(id: 10, frame: CGRect(x: 100, y: 80, width: 900, height: 650))

    @Test func desktopClickSelectsTheDisplayAndHoveringNeedsNoModeSwitch() {
        var state = CaptureSelectionState(displayFrame: screen, windows: [window])
        state.hover(at: CGPoint(x: 500, y: 200))
        #expect(state.target.kind == .window(10))
        state.hover(at: CGPoint(x: 1200, y: 800))
        #expect(state.target.kind == .display)
        state.mouseDown(at: CGPoint(x: 1200, y: 800))
        #expect(state.mouseUp(at: CGPoint(x: 1200, y: 800))?.rect == screen)
    }

    @Test func clickChoosesFrontmostWindowAndStaysFrozenAfterConfirmation() {
        let front = CaptureWindow(id: 11, frame: CGRect(x: 300, y: 160, width: 400, height: 300))
        var state = CaptureSelectionState(displayFrame: screen, windows: [front, window])
        state.mouseDown(at: CGPoint(x: 400, y: 200))
        let selection = state.mouseUp(at: CGPoint(x: 402, y: 201))
        #expect(selection == CaptureTarget(kind: .window(11), rect: front.frame))
        state.hover(at: CGPoint(x: 1200, y: 800))
        state.mouseDown(at: CGPoint(x: 1200, y: 800))
        #expect(state.mouseUp(at: CGPoint(x: 1300, y: 850)) == nil)
        #expect(state.target == selection)
    }

    @Test func fullScreenApplicationSelectsDisplayButCanStillStartARegionDrag() {
        let fullScreen = CaptureWindow(id: 12, frame: screen)
        var state = CaptureSelectionState(displayFrame: screen, windows: [fullScreen])
        state.hover(at: CGPoint(x: 500, y: 200))
        #expect(state.target.kind == .display)
        state.mouseDown(at: CGPoint(x: 500, y: 200))
        state.mouseDragged(to: CGPoint(x: 300, y: 100))
        #expect(state.mouseUp(at: CGPoint(x: 300, y: 100)) ==
                CaptureTarget(kind: .region, rect: CGRect(x: 300, y: 100, width: 200, height: 100)))
    }

    @Test func windowDragCreatesRegionInsteadOfCapturingOnMouseDown() {
        var state = CaptureSelectionState(displayFrame: screen, windows: [window])
        state.mouseDown(at: CGPoint(x: 200, y: 200))
        #expect(!state.isConfirmed)
        #expect(state.mouseUp(at: CGPoint(x: 700, y: 600)) ==
                CaptureTarget(kind: .region, rect: CGRect(x: 200, y: 200, width: 500, height: 400)))
    }

    @Test func narrowAccidentalDragDoesNotBecomeAFullScreenCapture() {
        var state = CaptureSelectionState(displayFrame: screen, windows: [])
        state.mouseDown(at: CGPoint(x: 100, y: 100))
        state.mouseDragged(to: CGPoint(x: 500, y: 100))
        #expect(state.mouseUp(at: CGPoint(x: 500, y: 101)) == nil)
        #expect(!state.isConfirmed)
        state.mouseDown(at: CGPoint(x: 100, y: 100))
        #expect(state.mouseUp(at: CGPoint(x: 100, y: 100))?.kind == .display)
    }

    @Test func negativeDisplayAndSpanningWindowAreClippedToTheActiveDisplay() {
        let display = CGRect(x: -1200, y: -800, width: 1200, height: 800)
        let spanning = CaptureWindow(id: 20, frame: CGRect(x: -400, y: -600, width: 900, height: 900))
        var state = CaptureSelectionState(displayFrame: display, windows: [spanning])
        state.hover(at: CGPoint(x: -200, y: -400))
        #expect(state.target.rect == CGRect(x: -400, y: -600, width: 400, height: 600))
        state.mouseDown(at: CGPoint(x: -200, y: -400))
        #expect(state.mouseUp(at: CGPoint(x: 400, y: 400)) ==
                CaptureTarget(kind: .region, rect: CGRect(x: -200, y: -400, width: 200, height: 400)))
    }
}
