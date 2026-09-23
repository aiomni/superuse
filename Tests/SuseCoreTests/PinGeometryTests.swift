import Foundation
import CoreGraphics
import Testing
import SuseCore

struct PinGeometryTests {
    @Test func longImageStartsWithinTheDisplayWithoutChangingItsAspectRatioInput() {
        let screen = CGRect(x: -1920, y: 100, width: 1920, height: 1050)
        let content = CGSize(width: 800, height: 30_000)
        let frame = PinGeometry.initialFrame(contentSize: content, on: screen, anchor: CGPoint(x: -20, y: 1300))
        #expect(screen.contains(frame))
        #expect(frame.width == 640)
        #expect(frame.height <= screen.height * 0.75)
    }

    @Test func disconnectedDisplayReturnsWindowToRemainingVisibleArea() {
        let left = CGRect(x: -1600, y: 0, width: 1600, height: 900)
        let right = CGRect(x: 0, y: 50, width: 1440, height: 800)
        let pin = CGRect(x: -1400, y: 400, width: 500, height: 300)
        #expect(PinGeometry.recover(pin, screens: [left, right]) == pin)
        #expect(right.contains(PinGeometry.recover(pin, screens: [right])))
        #expect(PinGeometry.recover(pin, screens: []) == pin)
    }

    @Test func oversizedWindowFitsSmallerDisplayAndVisibleDockArea() {
        let screen = CGRect(x: 200, y: -900, width: 800, height: 550)
        let result = PinGeometry.constrain(CGRect(x: -1000, y: 500, width: 1800, height: 1000), to: screen)
        #expect(result == screen)
    }

    @Test func resourceLimitsRejectOverflowAndEnforceIndependentBudgets() {
        let limits = PinResourceLimits(count: 2, bytes: 1024)
        #expect(limits.accepts(bytes: 512, currentBytes: 512, currentCount: 1))
        #expect(!limits.accepts(bytes: 513, currentBytes: 512, currentCount: 1))
        #expect(!limits.accepts(bytes: 1, currentBytes: 0, currentCount: 2))
        #expect(!limits.accepts(bytes: Int.max, currentBytes: 512, currentCount: 1))
        #expect(!limits.accepts(bytes: 1, currentBytes: Int.max, currentCount: 1))
        #expect(limits.acceptsImage(width: 1600, height: 30_000))
        #expect(!limits.acceptsImage(width: Int.max, height: Int.max))
        #expect(!limits.acceptsImage(width: 0, height: 1))
    }
}
