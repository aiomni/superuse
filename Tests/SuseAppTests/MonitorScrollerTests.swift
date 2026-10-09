import AppKit
import Testing
@testable import Suse

@Suite(.serialized)
@MainActor
struct MonitorScrollerTests {
    @Test func hoverRestoresNativeKnobWithoutChangingItsHitAreaOrScrollPosition() throws {
        _ = NSApplication.shared
        let scroller = MonitorScroller(frame: CGRect(x: 0, y: 0, width: 16, height: 200))
        scroller.scrollerStyle = .legacy; scroller.isEnabled = true
        scroller.doubleValue = 0.4; scroller.knobProportion = 0.25
        let native = scroller.rect(for: .knob)
        #expect(native.width > 4 && native.height > 0)
        #expect(scroller.displayedKnobRect.width <= 4)
        #expect(scroller.displayedKnobRect.height == native.height)
        let hit = scroller.testPart(scroller.convert(CGPoint(x: native.midX, y: native.midY), to: nil))
        #expect(hit == .knob)
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        scroller.mouseEntered(with: event)
        #expect(scroller.isHovered)
        #expect(scroller.displayedKnobRect == native)
        #expect(scroller.testPart(scroller.convert(CGPoint(x: native.midX, y: native.midY), to: nil)) == hit)
        #expect(scroller.doubleValue == 0.4)
        #expect(scroller.knobProportion == 0.25)
        scroller.mouseExited(with: event)
        #expect(!scroller.isHovered)
        #expect(scroller.displayedKnobRect.width <= 4)
        #expect(scroller.rect(for: .knob) == native)
    }

    @Test func fitsBothSystemScrollerStylesAndDoesNotReserveMoreSpaceOnHover() throws {
        _ = NSApplication.shared
        for style in [NSScroller.Style.legacy, .overlay] {
            let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 240, height: 200))
            scroll.scrollerStyle = style
            scroll.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 220, height: 1000))
            MonitorScroller.install(in: scroll); scroll.tile()
            let scroller = try #require(scroll.verticalScroller as? MonitorScroller)
            #expect(scroller.scrollerStyle == style)
            let contentFrame = scroll.contentView.frame
            let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                           windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            scroller.mouseEntered(with: event); scroll.layoutSubtreeIfNeeded()
            #expect(scroll.contentView.frame == contentFrame)
        }
    }
}
