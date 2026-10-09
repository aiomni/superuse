import AppKit
import SuseCore
import Testing
@testable import Suse

@Suite(.serialized)
@MainActor
struct CaptureRegionAdjustmentTests {
    @Test(arguments: [CGFloat(1), 2])
    func movingAndResizingUseTheFrozenSourceAndExportNativePixels(scale: CGFloat) throws {
        let fixture = try makeFixture(scale: scale)
        defer { fixture.pasteboard.releaseGlobally() }
        let original = fixture.controller.selectionRect
        var changed: [CGRect] = []
        fixture.controller.onRegionChange = { rect in
            changed.append(rect)
            fixture.background.setReviewSelection(rect)
        }
        #expect(fixture.canvas.tool == .select)
        #expect(fixture.adjustment.allowsMove)
        let start = CGPoint(x: original.midX, y: original.midY)
        try drag(from: start, to: CGPoint(x: start.x + 70, y: start.y + 35), in: fixture)
        let moved = original.offsetBy(dx: 70, dy: 35)
        #expect(fixture.controller.selectionRect == moved)
        #expect(changed.last == moved)
        #expect(fixture.canvas.annotationCount == 0)
        try expectExportMatchesSource(fixture)
        let right = CaptureRegionHandle.right.point(in: moved)
        try drag(from: right, to: CGPoint(x: right.x + 60, y: right.y + 80), in: fixture)
        #expect(fixture.controller.selectionRect == CGRect(x: moved.minX, y: moved.minY, width: moved.width + 60, height: moved.height))
        let bottom = CaptureRegionHandle.bottom.point(in: fixture.controller.selectionRect)
        try drag(from: bottom, to: CGPoint(x: bottom.x - 50, y: bottom.y + 45), in: fixture)
        #expect(fixture.controller.selectionRect.height == moved.height + 45)
        try expectExportMatchesSource(fixture)
        let labels = descendants(fixture.controller.view).compactMap { $0 as? NSTextField }
        let status = try #require(labels.first { $0.accessibilityIdentifier() == "capture-status" })
        #expect(status.stringValue.contains("\(fixture.canvas.image.width) × \(fixture.canvas.image.height)"))
        #expect(fixture.canvas.undoManager?.canUndo == false)
    }

    @Test(arguments: [false, true])
    func adjustmentCopiesOnlyOnReleaseWhenAutomaticCopyIsEnabled(automatic: Bool) throws {
        let fixture = try makeFixture(automaticCopy: automatic)
        defer { fixture.pasteboard.releaseGlobally() }
        fixture.pasteboard.setString("fixture", forType: .string)
        let start = CGPoint(x: 350, y: 220)
        fixture.adjustment.mouseDown(with: try mouse(.leftMouseDown, at: start, in: fixture))
        fixture.adjustment.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 370, y: 250), in: fixture))
        #expect(fixture.pasteboard.string(forType: .string) == "fixture")
        fixture.adjustment.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 400, y: 270), in: fixture))
        if automatic {
            let data = try #require(fixture.pasteboard.data(forType: .png))
            let image = try #require(NSBitmapImageRep(data: data)?.cgImage)
            #expect(pixels(image) == pixels(try fixture.canvas.renderedImage()))
        } else { #expect(fixture.pasteboard.string(forType: .string) == "fixture") }
    }

    @Test func finalMouseUpReturningToStartRestoresTheOriginalCrop() throws {
        let fixture = try makeFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        let original = fixture.controller.selectionRect
        let start = CGPoint(x: original.midX, y: original.midY)
        fixture.adjustment.mouseDown(with: try mouse(.leftMouseDown, at: start, in: fixture))
        fixture.adjustment.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: start.x + 80, y: start.y + 30), in: fixture))
        fixture.adjustment.mouseUp(with: try mouse(.leftMouseUp, at: start, in: fixture))
        #expect(fixture.controller.selectionRect == original)
        try expectExportMatchesSource(fixture)
    }

    @Test func pickingAToolAllowsDrawingAndFirstAnnotationLocksTheCrop() throws {
        let fixture = try makeFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        let picker = try #require(descendants(fixture.controller.view).compactMap { $0 as? NSSegmentedControl }
            .first { $0.segmentCount == AnnotationTool.allCases.count })
        picker.selectedSegment = AnnotationTool.rectangle.rawValue
        picker.sendAction(picker.action, to: picker.target)
        #expect(!fixture.adjustment.allowsMove)
        #expect(!fixture.adjustment.isHidden)
        let local = CGPoint(x: 50, y: 50)
        let point = fixture.canvas.convert(local, to: fixture.controller.view.superview)
        #expect(fixture.controller.view.hitTest(point) === fixture.canvas)
        let eventStart = try mouse(.leftMouseDown, at: CGPoint(x: 250, y: 170), in: fixture)
        let eventEnd = try mouse(.leftMouseUp, at: CGPoint(x: 350, y: 270), in: fixture)
        fixture.canvas.mouseDown(with: eventStart)
        fixture.canvas.mouseUp(with: eventEnd)
        #expect(fixture.canvas.annotationCount == 1)
        #expect(fixture.adjustment.isHidden)
        let selected = fixture.controller.selectionRect
        fixture.canvas.undoEdit()
        #expect(fixture.canvas.annotationCount == 0)
        #expect(fixture.adjustment.isHidden) // Never reinterpret earlier annotation coordinates after editing starts.
        try drag(from: CGPoint(x: selected.midX, y: selected.midY), to: CGPoint(x: selected.midX + 50, y: selected.midY + 50), in: fixture,
                 checkHit: false)
        #expect(fixture.controller.selectionRect == selected)
        fixture.canvas.undoEdit(redo: true)
        #expect(fixture.canvas.annotationCount == 1)
    }

    @Test func openingInlineTextLocksCropAndPinUsesTheAdjustedImage() throws {
        var pinned: CGImage?
        let fixture = try makeFixture(onPin: { pinned = $0 })
        defer { fixture.pasteboard.releaseGlobally() }
        try drag(from: CGPoint(x: 350, y: 220), to: CGPoint(x: 410, y: 260), in: fixture)
        fixture.controller.pinImage()
        #expect(pixels(try #require(pinned)) == pixels(try fixture.canvas.renderedImage()))
        let picker = try #require(descendants(fixture.controller.view).compactMap { $0 as? NSSegmentedControl }
            .first { $0.segmentCount == AnnotationTool.allCases.count })
        picker.selectedSegment = AnnotationTool.text.rawValue
        picker.sendAction(picker.action, to: picker.target)
        fixture.canvas.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 320, y: 230), in: fixture))
        #expect(fixture.canvas.textEditor != nil)
        #expect(fixture.adjustment.isHidden)
    }

    @Test func cropGesturesStayInsideTheDisplayAndDoNotStealToolbarClicks() throws {
        let fixture = try makeFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        let complete = try #require(descendants(fixture.controller.view).compactMap { $0 as? NSButton }.first { $0.title == "完成" })
        let point = complete.convert(CGPoint(x: complete.bounds.midX, y: complete.bounds.midY), to: fixture.controller.view.superview)
        #expect(fixture.controller.view.hitTest(point) === complete)
        try drag(from: CGPoint(x: 350, y: 220), to: CGPoint(x: -1000, y: -1000), in: fixture)
        #expect(fixture.controller.selectionRect.origin == .zero)
        let right = CaptureRegionHandle.right.point(in: fixture.controller.selectionRect)
        try drag(from: right, to: CGPoint(x: 2000, y: right.y), in: fixture)
        #expect(fixture.controller.selectionRect.maxX == 1200)
        // The right handle remains hittable inside a full-width selection.
        try drag(from: CGPoint(x: 1196, y: right.y), to: CGPoint(x: 900, y: right.y), in: fixture)
        #expect(fixture.controller.selectionRect.maxX == 904)
        try expectExportMatchesSource(fixture)
    }

    @Test func stitchedReviewWithoutTheFrozenSourceHasNoCropAdjustment() throws {
        _ = NSApplication.shared
        let source = makeImage(scale: 1)
        let review = CaptureReviewController(image: source, selectionRect: CGRect(x: 200, y: 120, width: 360, height: 240),
                                             displaySize: CGSize(width: 1200, height: 800), allowsScrolling: false)
        #expect(!descendants(review.view).contains { $0 is CaptureRegionAdjustmentView })
    }

    @Test func cancellingWhileMovingDoesNotCopyOrCompleteAndBackgroundFollowsTheCrop() throws {
        let fixture = try makeFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        fixture.pasteboard.setString("fixture", forType: .string)
        var cancelled = false
        var completed = false
        fixture.window.onCancel = { cancelled = true }
        fixture.controller.onAction = { if case .done = $0 { completed = true } }
        let before = try #require(fixture.background.bitmapImageRepForCachingDisplay(in: fixture.background.bounds))
        fixture.background.cacheDisplay(in: fixture.background.bounds, to: before)
        let start = CGPoint(x: 350, y: 220)
        fixture.adjustment.mouseDown(with: try mouse(.leftMouseDown, at: start, in: fixture))
        fixture.adjustment.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 850, y: 250), in: fixture))
        let bitmap = try #require(fixture.background.bitmapImageRepForCachingDisplay(in: fixture.background.bounds))
        fixture.background.cacheDisplay(in: fixture.background.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / fixture.background.bounds.width
        let oldPoint = CGPoint(x: 250, y: 150)
        let newPoint = CGPoint(x: 750, y: 180)
        let oldColor = try #require(bitmap.colorAt(x: Int(oldPoint.x * scale), y: Int(oldPoint.y * scale))?.usingColorSpace(.sRGB))
        let originalColor = try #require(before.colorAt(x: Int(oldPoint.x * scale), y: Int(oldPoint.y * scale))?.usingColorSpace(.sRGB))
        #expect(oldColor.redComponent < originalColor.redComponent * 0.8)
        let newColor = try #require(bitmap.colorAt(x: Int(newPoint.x * scale), y: Int(newPoint.y * scale))?.usingColorSpace(.sRGB))
        let previouslyDimmed = try #require(before.colorAt(x: Int(newPoint.x * scale), y: Int(newPoint.y * scale))?.usingColorSpace(.sRGB))
        #expect(newColor.redComponent > previouslyDimmed.redComponent * 1.2)
        fixture.window.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                              windowNumber: fixture.window.windowNumber, context: nil,
                                                              characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                              isARepeat: false, keyCode: 53)))
        #expect(cancelled && !completed)
        #expect(fixture.pasteboard.string(forType: .string) == "fixture")
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
    func adjustedRegionKeepsControlsVisibleAndAnnotationAnchorsStable(appearance: NSAppearance.Name) throws {
        let fixture = try makeFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        fixture.window.appearance = NSAppearance(named: appearance)
        try drag(from: CGPoint(x: 350, y: 220), to: CGPoint(x: 750, y: 490), in: fixture)
        fixture.controller.view.layoutSubtreeIfNeeded()
        let toolbar = try #require(fixture.controller.view.subviews.first { $0 is NSGlassEffectContainerView })
        #expect(fixture.controller.view.bounds.contains(toolbar.frame))
        let bars = descendants(toolbar).compactMap { $0 as? NSGlassEffectView }
        let frames = bars.map(\.frame)
        try render(fixture, named: "region-adjustment-\(appearance.rawValue)")
        fixture.canvas.addText("固定选区后标注", at: CGPoint(x: 20, y: 20))
        fixture.controller.view.layoutSubtreeIfNeeded()
        #expect(bars.map(\.frame) == frames)
        #expect(fixture.adjustment.isHidden)
    }

    private struct Fixture {
        let controller: CaptureReviewController
        let window: SelectionWindow
        let canvas: AnnotationCanvas
        let adjustment: CaptureRegionAdjustmentView
        let background: SelectionView
        let source: CGImage
        let pasteboard: NSPasteboard
    }

    private func makeFixture(scale: CGFloat = 1, automaticCopy: Bool = false,
                             onPin: ((CGImage) throws -> Void)? = nil) throws -> Fixture {
        _ = NSApplication.shared
        let source = makeImage(scale: scale)
        let rect = CGRect(x: 200, y: 120, width: 360, height: 240)
        let crop = try #require(source.cropping(to: CGRect(x: rect.minX * scale, y: rect.minY * scale,
                                                          width: rect.width * scale, height: rect.height * scale)))
        let pasteboard = NSPasteboard.withUniqueName()
        let controller = CaptureReviewController(image: crop, selectionRect: rect, displaySize: CGSize(width: 1200, height: 800),
                                                 allowsScrolling: true, pasteboard: pasteboard, onPin: onPin,
                                                 sourceImage: source, copyAfterAdjustment: automaticCopy)
        let window = SelectionWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
                                     styleMask: .borderless, backing: .buffered, defer: false)
        let background = SelectionView(image: source, displayFrame: CGRect(x: 0, y: 0, width: 1200, height: 800), windows: [])
        window.contentView = background
        background.freeze()
        background.setReviewSelection(rect)
        background.showReview(controller.view)
        controller.onRegionChange = { [weak background] in background?.setReviewSelection($0) }
        window.handleReviewKey = { [weak controller] in controller?.view.performKeyEquivalent(with: $0) ?? false }
        controller.view.layoutSubtreeIfNeeded()
        let canvas = try #require(descendants(controller.view).first { $0 is AnnotationCanvas } as? AnnotationCanvas)
        let adjustment = try #require(descendants(controller.view).first { $0 is CaptureRegionAdjustmentView } as? CaptureRegionAdjustmentView)
        return Fixture(controller: controller, window: window, canvas: canvas, adjustment: adjustment, background: background,
                       source: source, pasteboard: pasteboard)
    }

    private func drag(from start: CGPoint, to end: CGPoint, in fixture: Fixture, checkHit: Bool = true) throws {
        if checkHit {
            let point = fixture.controller.view.convert(start, to: fixture.controller.view.superview)
            #expect(fixture.controller.view.hitTest(point) === fixture.adjustment)
        }
        fixture.adjustment.mouseDown(with: try mouse(.leftMouseDown, at: start, in: fixture))
        fixture.adjustment.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2), in: fixture))
        fixture.adjustment.mouseUp(with: try mouse(.leftMouseUp, at: end, in: fixture))
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in fixture: Fixture) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: fixture.controller.view.convert(point, to: nil), modifierFlags: [],
                                       timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func expectExportMatchesSource(_ fixture: Fixture) throws {
        let cropRect = ScreenGeometry.pixelCrop(selection: fixture.controller.selectionRect,
                                                displayFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                                                pixelSize: CGSize(width: fixture.source.width, height: fixture.source.height))
        let expected = try #require(fixture.source.cropping(to: cropRect))
        let result = try fixture.canvas.renderedImage()
        #expect(result.width == expected.width && result.height == expected.height)
        #expect(pixels(result) == pixels(expected))
    }

    private func makeImage(scale: CGFloat) -> CGImage {
        let width = Int(1200 * scale), height = Int(800 * scale)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                bytes[index] = UInt8((x / 5) % 200 + 30)
                bytes[index + 1] = UInt8((y / 4) % 200 + 30)
                bytes[index + 2] = UInt8((x / 9 + y / 7) % 200 + 30)
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func pixels(_ image: CGImage) -> Data {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: image.width * image.height * 4)
    }

    private func render(_ fixture: Fixture, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SUSE_UI_PREVIEW_DIRECTORY"] else { return }
        let view = fixture.background
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        fixture.window.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(name).png"))
    }
}
