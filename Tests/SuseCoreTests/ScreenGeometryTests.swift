import Foundation
import CoreGraphics
import Testing
@testable import SuseCore

@Test func stackedAndNegativeDisplaysUseMainDisplayOrigin() {
    let upper = CGRect(x: -1200, y: 900, width: 1200, height: 800)
    #expect(ScreenGeometry.quartzRect(fromAppKit: upper, mainDisplayHeight: 900) ==
            CGRect(x: -1200, y: -800, width: 1200, height: 800))
    #expect(ScreenGeometry.quartzRect(fromAppKit: CGRect(x: 0, y: -600, width: 800, height: 600), mainDisplayHeight: 900).minY == 900)
}

@Test func retinaCropClipsToDisplayAndUsesPixelCoordinates() {
    let crop = ScreenGeometry.pixelCrop(selection: CGRect(x: -150, y: 40, width: 100, height: 80),
                                          displayFrame: CGRect(x: -100, y: 0, width: 500, height: 300),
                                          pixelSize: CGSize(width: 1000, height: 600))
    #expect(crop == CGRect(x: 0, y: 80, width: 100, height: 160))
}
