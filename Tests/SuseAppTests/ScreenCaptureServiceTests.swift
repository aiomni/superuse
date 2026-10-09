import AppKit
import Testing
import SuseCore
@testable import Suse

@Suite(.serialized)
@MainActor
struct ScreenCaptureServiceTests {
    @Test(arguments: [CGFloat(1), 2])
    func liveCaptureMatchesFrozenCropAtFractionalEdges(scale: CGFloat) throws {
        let displayFrame = CGRect(x: -500, y: -300, width: 500, height: 300)
        let pixelSize = CGSize(width: 500 * scale, height: 300 * scale)
        // Integer dimensions still need outward rounding when the origin is fractional.
        let selections = [
            CGRect(x: 10.25, y: 20.25, width: 100.5, height: 80.5),
            CGRect(x: 10.25, y: 20.25, width: 100, height: 80),
            CGRect(x: 10, y: 20, width: 100, height: 80),
            CGRect(x: -20.25, y: 270.25, width: 100.5, height: 80.5),
            CGRect(origin: .zero, size: displayFrame.size),
        ]
        for selection in selections {
            let region = selection.offsetBy(dx: displayFrame.minX, dy: displayFrame.minY)
            let crop = ScreenGeometry.pixelCrop(selection: region, displayFrame: displayFrame, pixelSize: pixelSize)
            let config = try ScreenCaptureService().regionConfiguration(region: region, displayFrame: displayFrame,
                                                                        pixelSize: pixelSize)
            #expect(config.width == Int(crop.width))
            #expect(config.height == Int(crop.height))
            // Matching dimensions alone is insufficient: both paths must sample the same pixels.
            #expect(config.sourceRect == CGRect(x: crop.minX / scale, y: crop.minY / scale,
                                                width: crop.width / scale, height: crop.height / scale))
            #expect(!config.showsCursor)
            #expect(config.dynamicRange == .sdr)
        }
    }

    @Test func liveCaptureUsesActualSnapshotPixelDimensions() throws {
        let displayFrame = CGRect(x: 0, y: 0, width: 500, height: 300)
        let pixelSize = CGSize(width: 751, height: 451)
        let region = CGRect(x: 10, y: 20, width: 100, height: 80)
        let config = try ScreenCaptureService().regionConfiguration(region: region, displayFrame: displayFrame,
                                                                    pixelSize: pixelSize)
        #expect(config.width == 151)
        #expect(config.height == 121)
        #expect(abs(config.sourceRect.minX * pixelSize.width / displayFrame.width - 15) < 0.000_001)
        #expect(abs(config.sourceRect.minY * pixelSize.height / displayFrame.height - 30) < 0.000_001)
    }

    @Test func liveCaptureRejectsEmptyOrUnavailableRegions() {
        let displayFrame = CGRect(x: -500, y: -300, width: 500, height: 300)
        for region in [CGRect.zero, CGRect(x: 10, y: 10, width: 100, height: 80)] {
            #expect(throws: AppError.self) {
                try ScreenCaptureService().regionConfiguration(region: region, displayFrame: displayFrame,
                                                               pixelSize: CGSize(width: 1000, height: 600))
            }
        }
    }
}
