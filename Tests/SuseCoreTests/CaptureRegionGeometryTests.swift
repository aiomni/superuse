import CoreGraphics
import Testing
@testable import SuseCore

struct CaptureRegionGeometryTests {
    @Test(arguments: [CGPoint.zero, CGPoint(x: -1440, y: -900)])
    func movementPreservesDimensionsAndClampsToTheSameDisplay(origin: CGPoint) {
        let display = CGRect(origin: origin, size: CGSize(width: 1440, height: 900))
        let rect = CGRect(x: origin.x + 100, y: origin.y + 120, width: 600, height: 400)
        let start = CGPoint(x: rect.midX, y: rect.midY)
        let adjustment = CaptureRegionAdjustment(rect: rect, displayFrame: display, start: start, handle: nil)
        #expect(adjustment.rect(at: CGPoint(x: start.x + 35, y: start.y - 15)) == rect.offsetBy(dx: 35, dy: -15))
        #expect(adjustment.rect(at: CGPoint(x: display.minX - 1000, y: display.minY - 1000)) ==
                CGRect(origin: display.origin, size: rect.size))
        #expect(adjustment.rect(at: CGPoint(x: display.maxX + 1000, y: display.maxY + 1000)) ==
                CGRect(x: display.maxX - rect.width, y: display.maxY - rect.height, width: rect.width, height: rect.height))
    }

    @Test(arguments: CaptureRegionHandle.allCases)
    func eachHandleAdjustsOnlyItsEdges(handle: CaptureRegionHandle) {
        let rect = CGRect(x: 100, y: 120, width: 600, height: 400)
        let start = handle.point(in: rect)
        let adjustment = CaptureRegionAdjustment(rect: rect, displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                                start: start, handle: handle)
        let result = adjustment.rect(at: CGPoint(x: start.x + 30, y: start.y + 20))
        let expectedLeft: CGFloat = [.topLeft, .left, .bottomLeft].contains(handle) ? 130 : 100
        let expectedRight: CGFloat = [.topRight, .right, .bottomRight].contains(handle) ? 730 : 700
        let expectedTop: CGFloat = [.topLeft, .top, .topRight].contains(handle) ? 140 : 120
        let expectedBottom: CGFloat = [.bottomLeft, .bottom, .bottomRight].contains(handle) ? 540 : 520
        #expect(result == CGRect(x: expectedLeft, y: expectedTop, width: expectedRight - expectedLeft,
                                 height: expectedBottom - expectedTop))
    }

    @Test(arguments: CaptureRegionHandle.allCases)
    func handlesDoNotCrossOrLeaveNegativeOriginDisplays(handle: CaptureRegionHandle) {
        let display = CGRect(x: -1440, y: -900, width: 1440, height: 900)
        let rect = CGRect(x: -1000, y: -600, width: 600, height: 400)
        let start = handle.point(in: rect)
        let adjustment = CaptureRegionAdjustment(rect: rect, displayFrame: display, start: start, handle: handle)
        for point in [CGPoint(x: -3000, y: -3000), CGPoint(x: 3000, y: 3000)] {
            let result = adjustment.rect(at: point)
            #expect(display.contains(result))
            #expect(result.width >= 4 && result.height >= 4)
        }
    }

    @Test func fractionalRetinaAdjustmentKeepsTheSnapshotPixelGrid() {
        let display = CGRect(x: -1200, y: -800, width: 1200, height: 800)
        let rect = CGRect(x: -1179.75, y: -770.25, width: 140.5, height: 110.5)
        let start = CaptureRegionHandle.bottomRight.point(in: rect)
        let adjustment = CaptureRegionAdjustment(rect: rect, displayFrame: display, start: start, handle: .bottomRight)
        let resized = adjustment.rect(at: CGPoint(x: start.x + 10.25, y: start.y + 20.25))
        let crop = ScreenGeometry.pixelCrop(selection: resized, displayFrame: display, pixelSize: CGSize(width: 2400, height: 1600))
        #expect(crop == CGRect(x: 40, y: 59, width: 302, height: 262))
    }
}
