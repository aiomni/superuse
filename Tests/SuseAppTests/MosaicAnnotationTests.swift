import AppKit
import Testing
@testable import Suse

@Suite(.serialized)
@MainActor
struct MosaicAnnotationTests {
    @Test(arguments: [CGFloat(1), 2], [false, true])
    func mosaicExportsOnlyTheSelectedRegionAndSupportsUndo(scale: CGFloat, reverse: Bool) throws {
        let fixture = try makeFixture(scale: scale)
        defer { fixture.pasteboard.releaseGlobally() }
        let region = CGRect(x: 16, y: 12, width: 64, height: 40)
        let original = pixels(fixture.canvas.image)
        try drag(region, in: fixture, reverse: reverse)
        #expect(fixture.canvas.annotationCount == 1)
        #expect(!fixture.scrolling.isEnabled)

        fixture.controller.copyImage(completing: false)
        let png = try #require(fixture.pasteboard.data(forType: .png))
        let exported = try #require(NSBitmapImageRep(data: png)?.cgImage)
        #expect(exported.width == fixture.canvas.image.width)
        #expect(exported.height == fixture.canvas.image.height)
        let result = pixels(exported)
        var changed = 0
        var colors = Set<Data>()
        for y in 0..<exported.height {
            for x in 0..<exported.width {
                let index = (y * exported.width + x) * 4
                let pixel = result[index..<index + 4]
                if region.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                    if pixel != original[index..<index + 4] { changed += 1 }
                    colors.insert(pixel)
                } else {
                    #expect(pixel == original[index..<index + 4])
                }
            }
        }
        #expect(changed > Int(region.width * region.height * 0.8))
        #expect(colors.count > 1 && colors.count < 100)
        fixture.canvas.undoManager?.undo()
        #expect(pixels(try fixture.canvas.renderedImage()) == original)
        #expect(fixture.scrolling.isEnabled)
        fixture.canvas.undoManager?.redo()
        #expect(pixels(try fixture.canvas.renderedImage()) == result)
        #expect(!fixture.scrolling.isEnabled)
    }

    @Test func mosaicStrengthIsRetainedForEachAnnotation() throws {
        let fixture = try makeFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        let region = CGRect(x: 0, y: 0, width: 128, height: 96)
        fixture.canvas.lineWidth = 2
        try drag(region, in: fixture)
        let fine = pixels(try fixture.canvas.renderedImage())
        fixture.canvas.lineWidth = 10
        #expect(pixels(try fixture.canvas.renderedImage()) == fine)
        fixture.canvas.clear()
        try drag(region, in: fixture)
        let coarse = pixels(try fixture.canvas.renderedImage())
        func colorCount(_ data: Data) -> Int {
            Set(stride(from: 0, to: data.count, by: 4).map { data[$0..<$0 + 4] }).count
        }
        #expect(colorCount(coarse) < colorCount(fine))
    }

    @Test(arguments: [CGRect(x: 0, y: 0, width: 128, height: 96),
                      CGRect(x: 16, y: 8, width: 64, height: 40)])
    func mosaicKeepsExistingRedactionsCovered(region: CGRect) throws {
        let fixture = try makeFixture(tool: .redact)
        defer { fixture.pasteboard.releaseGlobally() }
        let history = try #require(fixture.canvas.undoManager)
        history.groupsByEvent = false
        history.beginUndoGrouping()
        try drag(region, in: fixture)
        history.endUndoGrouping()
        let covered = pixels(try fixture.canvas.renderedImage())

        fixture.canvas.tool = .mosaic
        fixture.canvas.lineWidth = 2
        history.beginUndoGrouping()
        try drag(region, in: fixture)
        history.endUndoGrouping()
        #expect(fixture.canvas.annotationCount == 2)
        #expect(pixels(try fixture.canvas.renderedImage()) == covered)
        fixture.canvas.undoManager?.undo()
        #expect(pixels(try fixture.canvas.renderedImage()) == covered)
        fixture.canvas.undoManager?.redo()
        #expect(pixels(try fixture.canvas.renderedImage()) == covered)
    }

    @Test(arguments: [AnnotationTool.mosaic, .redact])
    func redactionIsOpaqueAndEmptyDragsDoNotChangeTheImage(tool: AnnotationTool) throws {
        let fixture = try makeFixture(tool: tool, transparent: true)
        defer { fixture.pasteboard.releaseGlobally() }
        fixture.canvas.ink = .clear
        let original = pixels(fixture.canvas.image)
        for region in [CGRect(x: 20, y: 20, width: 0, height: 0),
                       CGRect(x: 20, y: 20, width: 30, height: 0)] {
            try drag(region, in: fixture)
            #expect(fixture.canvas.annotationCount == 0)
            #expect(pixels(try fixture.canvas.renderedImage()) == original)
            #expect(fixture.scrolling.isEnabled)
        }
        try drag(CGRect(x: -10, y: -10, width: 148, height: 116), in: fixture, reverse: true)
        let result = pixels(try fixture.canvas.renderedImage())
        #expect(stride(from: 3, to: result.count, by: 4).allSatisfy { result[$0] == 255 })
        if tool == .redact {
            #expect(stride(from: 0, to: result.count, by: 4).allSatisfy {
                result[$0] == 0 && result[$0 + 1] == 0 && result[$0 + 2] == 0
            })
        }
    }

    private struct Fixture {
        let controller: CaptureReviewController
        let window: NSWindow
        let canvas: AnnotationCanvas
        let scrolling: NSButton
        let pasteboard: NSPasteboard
        let scale: CGFloat
    }

    private func makeFixture(scale: CGFloat = 1, tool: AnnotationTool = .mosaic,
                             transparent: Bool = false) throws -> Fixture {
        _ = NSApplication.shared
        let image = imageFixture(transparent: transparent)
        let size = CGSize(width: 1200, height: 800)
        let pasteboard = NSPasteboard.withUniqueName()
        let controller = CaptureReviewController(image: image,
            selectionRect: CGRect(x: 200, y: 100, width: 128 / scale, height: 96 / scale),
            displaySize: size, allowsScrolling: true, pasteboard: pasteboard)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentViewController = controller
        let views = descendants(controller.view)
        let canvas = try #require(views.first { $0 is AnnotationCanvas } as? AnnotationCanvas)
        let picker = try #require(views.compactMap { $0 as? NSSegmentedControl }
            .first { $0.segmentCount == AnnotationTool.allCases.count })
        #expect(picker.image(forSegment: tool.rawValue) != nil)
        picker.selectedSegment = tool.rawValue
        picker.sendAction(picker.action, to: picker.target)
        let color = try #require(views.first { $0 is NSColorWell } as? NSColorWell)
        #expect(!color.isEnabled)
        let scrolling = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == "滚动截图" })
        #expect(scrolling.isEnabled)
        return Fixture(controller: controller, window: window, canvas: canvas, scrolling: scrolling,
                       pasteboard: pasteboard, scale: scale)
    }

    private func drag(_ rect: CGRect, in fixture: Fixture, reverse: Bool = false) throws {
        let first = CGPoint(x: rect.minX / fixture.scale, y: rect.minY / fixture.scale)
        let last = CGPoint(x: rect.maxX / fixture.scale, y: rect.maxY / fixture.scale)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: fixture.canvas.convert(point, to: nil),
                                           modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        fixture.canvas.mouseDown(with: try event(.leftMouseDown, reverse ? last : first))
        // The final mouse-up location can differ from the last drag event.
        fixture.canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: (first.x + last.x) / 2,
                                                                             y: (first.y + last.y) / 2)))
        fixture.canvas.mouseUp(with: try event(.leftMouseUp, reverse ? first : last))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func imageFixture(transparent: Bool) -> CGImage {
        let width = 128, height = 96
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let divisor = transparent ? 2 : 1
                data[index] = UInt8(((x * 17 + y * 11) % 256) / divisor)
                data[index + 1] = UInt8(((x * 7 + y * 23) % 256) / divisor)
                data[index + 2] = UInt8(((x * 13 + y * 3) % 256) / divisor)
                data[index + 3] = transparent ? 128 : 255
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func pixels(_ image: CGImage) -> Data {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }
}
