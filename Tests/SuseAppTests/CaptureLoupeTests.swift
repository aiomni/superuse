import AppKit
import SuseCore
import Testing
@testable import Suse

@Suite(.serialized)
@MainActor
struct CaptureLoupeTests {
    @Test func colorInspectionWorksForScreenWindowAndDraggedRegion() throws {
        let fixture = try makeFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        var confirmed: CaptureTarget?
        fixture.view.onSelect = { confirmed = $0; fixture.view.freeze() }
        let loupe = try #require(fixture.view.subviews.first { $0 is CaptureLoupeView } as? CaptureLoupeView)
        let point = CGPoint(x: 20, y: 20)
        fixture.view.mouseMoved(with: try mouse(.mouseMoved, point, fixture))
        #expect(!loupe.isHidden)
        #expect(loupe.accessibilityLabel()?.contains("全屏") == true)
        #expect(loupe.accessibilityLabel()?.contains("X: 40   Y: 40") == true)
        #expect(loupe.hitTest(.zero) == nil)
        fixture.view.mouseMoved(with: try mouse(.mouseMoved, CGPoint(x: 200, y: 180), fixture))
        #expect(loupe.accessibilityLabel()?.contains("窗口") == true)
        fixture.view.mouseDown(with: try mouse(.leftMouseDown, point, fixture))
        fixture.view.mouseDragged(with: try mouse(.leftMouseDragged, CGPoint(x: 300, y: 240), fixture))
        #expect(confirmed == nil)
        #expect(!loupe.isHidden)
        #expect(loupe.accessibilityLabel()?.contains("区域") == true)
        fixture.window.sendEvent(try key(.keyDown, code: 8, modifiers: [.command], fixture))
        #expect(fixture.pasteboard.string(forType: .string) == "rgb(51, 102, 153)")
        #expect(confirmed == nil)
        fixture.view.mouseUp(with: try mouse(.leftMouseUp, CGPoint(x: 300, y: 240), fixture))
        #expect(confirmed?.kind == .region)
        #expect(loupe.isHidden)
        let changes = fixture.pasteboard.changeCount
        #expect(!fixture.window.performKeyEquivalent(with: try key(.keyDown, code: 8, modifiers: [.command], fixture)))
        #expect(fixture.pasteboard.changeCount == changes)
    }

    @Test func shiftCyclesOncePerPressAndCopyDoesNotConfirmSelection() throws {
        let fixture = try makeFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        let point = CGPoint(x: 123.5, y: 87.25)
        fixture.view.mouseMoved(with: try mouse(.mouseMoved, point, fixture))
        let loupe = try #require(fixture.view.subviews.first { $0 is CaptureLoupeView } as? CaptureLoupeView)
        #expect(loupe.accessibilityLabel()?.contains("X: 247   Y: 174") == true)
        let initialChanges = fixture.pasteboard.changeCount
        let down = try key(.flagsChanged, code: 56, modifiers: [.shift], fixture)
        let up = try key(.flagsChanged, code: 56, modifiers: [], fixture)
        fixture.window.sendEvent(down)
        fixture.window.sendEvent(down)
        #expect(fixture.inspector.format == .hex)
        #expect(fixture.pasteboard.changeCount == initialChanges)
        #expect(fixture.window.performKeyEquivalent(with: try key(.keyDown, code: 8, modifiers: [.command], fixture)))
        #expect(fixture.pasteboard.string(forType: .string) == "#336699")
        #expect(loupe.accessibilityLabel()?.contains("HEX") == true)
        fixture.window.sendEvent(up)
        fixture.window.sendEvent(down)
        #expect(fixture.inspector.format == .hsl)
        fixture.window.sendEvent(up)
        fixture.window.sendEvent(try key(.keyDown, code: 8, modifiers: [.command], fixture))
        #expect(fixture.pasteboard.string(forType: .string) == "hsl(210, 50%, 40%)")
        fixture.window.sendEvent(down)
        fixture.window.sendEvent(up)
        #expect(fixture.inspector.format == .rgb)
        let changes = fixture.pasteboard.changeCount
        #expect(!fixture.window.performKeyEquivalent(with: try key(.keyDown, code: 8, modifiers: [.command, .option], fixture)))
        #expect(fixture.pasteboard.changeCount == changes)
        var cancelled = false
        fixture.window.onCancel = { cancelled = true }
        fixture.window.sendEvent(try key(.keyDown, code: 53, modifiers: [], fixture))
        #expect(cancelled)
    }

    @Test func loupeFitsAtScreenEdgesAndAcrossAppearancesWithoutDimmingFullScreen() throws {
        let fixture = try makeFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        let loupe = try #require(fixture.view.subviews.first { $0 is CaptureLoupeView } as? CaptureLoupeView)
        for appearance in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            fixture.window.appearance = NSAppearance(named: appearance)
            for cursor in [CGPoint(x: 1, y: 1), CGPoint(x: 599, y: 1), CGPoint(x: 599, y: 399), CGPoint(x: 1, y: 399)] {
                fixture.view.mouseMoved(with: try mouse(.mouseMoved, cursor, fixture))
                fixture.view.layoutSubtreeIfNeeded()
                #expect(fixture.view.bounds.contains(loupe.frame))
                #expect(!loupe.frame.contains(cursor))
                #expect(loupe.frame.width < 220 && loupe.frame.height < 260)
                let visibleLabels = descendants(loupe).compactMap { $0 as? NSTextField }.map(\.stringValue)
                #expect(!visibleLabels.contains { $0.contains("确认") })
            }
        }
        fixture.view.mouseMoved(with: try mouse(.mouseMoved, CGPoint(x: 20, y: 20), fixture))
        let bitmap = try #require(fixture.view.bitmapImageRepForCachingDisplay(in: fixture.view.bounds))
        fixture.view.cacheDisplay(in: fixture.view.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["SUSE_UI_PREVIEW_DIRECTORY"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output.appending(path: "capture-loupe.png"))
        }
        // Layer-backed AppKit views can omit their own drawing from offscreen
        // cacheDisplay snapshots. Verify the selection canvas directly in sRGB.
        let canvas = try renderCanvas(fixture.view)
        let sampler = CapturePixelSampler(image: canvas, displayFrame: fixture.view.bounds)
        let color = try #require(sampler.sample(at: CGPoint(x: 400, y: 300))?.color)
        #expect(color == CaptureColor(red: 51, green: 102, blue: 153))
        for point in [CGPoint(x: 300, y: 3), CGPoint(x: 300, y: 397), CGPoint(x: 3, y: 300), CGPoint(x: 597, y: 300)] {
            let edge = try #require(sampler.sample(at: point)?.color)
            #expect(edge != color)
        }
        fixture.view.mouseExited(with: try mouse(.mouseMoved, .zero, fixture))
        #expect(loupe.isHidden)
    }

    @Test func magnifierKeepsTheSampledPixelCenteredAtImageEdges() throws {
        var bytes = [UInt8]()
        for y in 0..<4 {
            for x in 0..<6 { bytes += [UInt8(x * 40), UInt8(y * 60), 30, 255] }
        }
        let image = try #require(CGImage(width: 6, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 24,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                        provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                                        shouldInterpolate: false, intent: .defaultIntent))
        let loupe = CaptureLoupeView(image: image)
        let magnifier = try #require(descendants(loupe).first { $0.accessibilityIdentifier() == "capture-magnifier" })
        let sampler = CapturePixelSampler(image: image, displayFrame: CGRect(x: 0, y: 0, width: 6, height: 4))
        for point in [CGPoint.zero, CGPoint(x: 5, y: 3), CGPoint(x: 0, y: 3), CGPoint(x: 3, y: 2)] {
            let sample = try #require(sampler.sample(at: point))
            loupe.update(sample: sample, format: .rgb, kind: .display)
            let rendered = CapturePixelSampler(image: try renderCanvas(magnifier), displayFrame: magnifier.bounds)
            let center = CGPoint(x: magnifier.bounds.midX, y: magnifier.bounds.midY)
            #expect(rendered.sample(at: center)?.color == sample.color)
        }
    }

    private struct Fixture {
        let view: SelectionView
        let window: SelectionWindow
        let inspector: CaptureColorInspector
        let pasteboard: NSPasteboard
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func renderCanvas(_ view: NSView) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: Int(view.bounds.width), height: Int(view.bounds.height),
                                            bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: view.bounds.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        view.draw(view.bounds)
        return try #require(context.makeImage())
    }

    private func makeFixture() throws -> Fixture {
        _ = NSApplication.shared
        let context = try #require(CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        let pasteboard = NSPasteboard.withUniqueName()
        let inspector = CaptureColorInspector(pasteboard: pasteboard)
        let frame = CGRect(x: -600, y: -200, width: 600, height: 400)
        let view = SelectionView(image: try #require(context.makeImage()), displayFrame: frame,
                                 windows: [CaptureWindow(id: 42, frame: CGRect(x: -450, y: -50, width: 200, height: 180))],
                                 inspector: inspector)
        let window = SelectionWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
                                     styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.handleSelectionKey = { [weak view] in view?.handleInspectionEvent($0) ?? false }
        return Fixture(view: view, window: window, inspector: inspector, pasteboard: pasteboard)
    }

    private func mouse(_ type: NSEvent.EventType, _ point: CGPoint, _ fixture: Fixture) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: fixture.view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                       windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func key(_ type: NSEvent.EventType, code: UInt16, modifiers: NSEvent.ModifierFlags, _ fixture: Fixture) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                     windowNumber: fixture.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                     isARepeat: false, keyCode: code))
    }
}
