import AppKit
import Foundation
import Testing
import SuseCore
@testable import Suse

@Suite(.serialized)
@MainActor
struct NativeIntegrationTests {
    private func isolatedStore() -> (ClipboardStore, SettingsStore, NSPasteboard, URL, String) {
        let suite = "app.suse.tests.\(UUID().uuidString)"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        let pasteboard = NSPasteboard.withUniqueName()
        let path = FileManager.default.temporaryDirectory.appending(path: "\(suite)/history.json")
        return (ClipboardStore(settings: settings, pasteboard: pasteboard, persistenceURL: path), settings, pasteboard, path, suite)
    }

    @Test func clipboardCaptureEditCopyAndSensitiveFiltering() async throws {
        let (store, settings, pasteboard, path, suite) = isolatedStore()
        defer {
            settings.defaults.removePersistentDomain(forName: suite)
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: path.deletingLastPathComponent())
        }
        pasteboard.clearContents()
        pasteboard.setString("first", forType: .string)
        store.checkForChanges()
        let entry = try #require(store.history.entries.first)
        #expect(entry.content == .text("first"))
        #expect(store.edit(entry, text: "edited"))
        let edited = try #require(store.history.entries.first)
        #expect(store.copy(edited))
        #expect(pasteboard.string(forType: .string) == "edited")
        store.checkForChanges()
        #expect(store.history.entries.count == 1)

        pasteboard.clearContents()
        pasteboard.setString("sensitive", forType: .string)
        pasteboard.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        store.checkForChanges()
        #expect(store.history.entries.count == 1)
        settings.defaults.set(false, forKey: "clipboard.enabled")
        pasteboard.clearContents()
        pasteboard.setString("paused", forType: .string)
        store.checkForChanges()
        #expect(store.history.entries.count == 1)
        await store.flush()
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test func persistenceIsOptInAndDisablingRemovesDiskHistory() async throws {
        let (store, settings, pasteboard, path, suite) = isolatedStore()
        defer {
            settings.defaults.removePersistentDomain(forName: suite)
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: path.deletingLastPathComponent())
        }
        settings.defaults.set(true, forKey: "clipboard.persist")
        pasteboard.clearContents()
        pasteboard.setString("local history", forType: .string)
        store.checkForChanges()
        await store.flush()
        try #require(store.persistenceError == nil)
        let saved = try JSONDecoder().decode([ClipboardEntry].self, from: Data(contentsOf: path))
        #expect(saved.first?.content == .text("local history"))
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        settings.defaults.set(false, forKey: "clipboard.persist")
        store.settingsChanged()
        await store.flush()
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(store.history.entries.count == 1)
    }

    @Test func annotationExportPreservesOrientationAndUndo() throws {
        _ = NSApplication.shared
        let image = colorFixture()
        let canvas = AnnotationCanvas(image: image, displayWidth: 120)
        let unchanged = try canvas.renderedImage()
        #expect(pixels(unchanged) == pixels(image))
        canvas.addText("A", at: CGPoint(x: 12, y: 4))
        let annotated = try canvas.renderedImage()
        #expect(pixels(annotated) != pixels(image))
        #expect(annotated.width == image.width && annotated.height == image.height)
        canvas.undoManager?.undo()
        #expect(pixels(try canvas.renderedImage()) == pixels(image))
        canvas.undoManager?.redo()
        #expect(canvas.annotationCount == 1)
    }

    @Test func nativeWindowsCreateWithoutScreenCapturePermissions() throws {
        _ = NSApplication.shared
        let editor = CaptureReviewController(image: colorFixture(), selectionRect: CGRect(x: 100, y: 100, width: 240, height: 160),
                                             displaySize: CGSize(width: 1200, height: 800), allowsScrolling: true)
        editor.view.layoutSubtreeIfNeeded()
        #expect(editor.view.subviews.contains { $0 is NSGlassEffectView })
        let (store, settings, pasteboard, _, suite) = isolatedStore()
        defer { settings.defaults.removePersistentDomain(forName: suite); pasteboard.releaseGlobally() }
        let panel = ClipboardPanelController(store: store)
        panel.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(panel.window?.contentView is NSGlassEffectView)
        let glass = try #require(panel.window?.contentView as? NSGlassEffectView)
        let content = try #require(glass.contentView)
        #expect(content.fittingSize.height <= glass.bounds.height)
    }

    @Test func screenshotHasOneCommandAndPreservesThePreviousShortcutPreference() throws {
        let (_, settings, pasteboard, _, suite) = isolatedStore()
        defer { settings.defaults.removePersistentDomain(forName: suite); pasteboard.releaseGlobally() }
        let previous = Shortcut(keyCode: 22, modifiers: [.command, .shift])
        settings.save(shortcut: previous, for: "screenshot.region")
        let module = ScreenshotModule(settings: settings)
        #expect(module.commands.count == 1)
        let command = try #require(module.commands.first)
        #expect(command.defaultShortcut == Shortcut(keyCode: 0, modifiers: [.shift, .command]))
        let hub = ShortcutHub(settings: settings)
        #expect(hub.shortcut(for: command) == previous)
        settings.setShortcutDisabled(true, for: "screenshot.region")
        #expect(hub.shortcut(for: command) == nil)
    }

    @Test func reviewEditsInPlaceAndKeepsControlsOnScreen() throws {
        _ = NSApplication.shared
        for rect in [CGRect(x: 300, y: 150, width: 480, height: 320),
                     CGRect(x: 0, y: 0, width: 1200, height: 800),
                     CGRect(x: 1160, y: 760, width: 30, height: 20)] {
            let controller = CaptureReviewController(image: colorFixture(), selectionRect: rect,
                                                     displaySize: CGSize(width: 1200, height: 800), allowsScrolling: true)
            let view = controller.view
            view.layoutSubtreeIfNeeded()
            let scroll = try #require(view.subviews.first { $0 is NSScrollView } as? NSScrollView)
            let canvas = try #require(scroll.documentView as? AnnotationCanvas)
            #expect(scroll.frame == rect)
            #expect(!canvas.editingEnabled)
            let glass = try #require(view.subviews.first { $0 is NSGlassEffectView })
            #expect(view.bounds.contains(glass.frame))
            let buttons = descendants(of: view).compactMap { $0 as? NSButton }
            let edit = try #require(buttons.first { $0.title == "编辑" })
            edit.performClick(nil)
            view.layoutSubtreeIfNeeded()
            #expect(canvas.editingEnabled)
            #expect(scroll.frame == rect)
            #expect(view.bounds.contains(glass.frame))
            #expect(pixels(try canvas.renderedImage()) == pixels(colorFixture()))
            let scrolling = try #require(buttons.first { $0.title == "滚动截图" })
            #expect(!scrolling.isEnabled)
            edit.performClick(nil)
            #expect(!canvas.editingEnabled)
            #expect(scrolling.isEnabled)
        }
    }

    @Test func selectionWaitsForMouseUpAndRetainsTheOverlay() throws {
        _ = NSApplication.shared
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let view = SelectionView(image: colorFixture(), displayFrame: frame,
                                 windows: [CaptureWindow(id: 42, frame: CGRect(x: 100, y: 100, width: 600, height: 400))])
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        var result: CaptureTarget?
        view.onSelect = { result = $0; view.freeze() }
        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        // The view is flipped, while window event coordinates have a bottom-left origin.
        view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 200, y: 600)))
        #expect(result == nil)
        view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 500, y: 400)))
        view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 500, y: 400)))
        #expect(result == CaptureTarget(kind: .region, rect: CGRect(x: 200, y: 200, width: 300, height: 200)))
        #expect(window.contentView === view)
        #expect(window.frame == frame)
    }

    @Test func copyingReviewPreservesPixelsAndOnlyCompletesWhenRequested() throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let image = colorFixture()
        let controller = CaptureReviewController(image: image, selectionRect: CGRect(x: 100, y: 100, width: 240, height: 160),
                                                 displaySize: CGSize(width: 1200, height: 800), allowsScrolling: true,
                                                 pasteboard: pasteboard)
        _ = controller.view
        var completed = false
        controller.onAction = { if case .done = $0 { completed = true } }
        controller.copyImage(completing: false)
        let data = try #require(pasteboard.data(forType: .png))
        let original = try #require(NSBitmapImageRep(data: data)?.cgImage)
        #expect(pixels(original) == pixels(image))
        #expect(!completed)
        let canvas = try #require(descendants(of: controller.view).first { $0 is AnnotationCanvas } as? AnnotationCanvas)
        canvas.addText("A", at: CGPoint(x: 12, y: 4))
        controller.copyImage(completing: true)
        #expect(completed)
        let editedData = try #require(pasteboard.data(forType: .png))
        let edited = try #require(NSBitmapImageRep(data: editedData)?.cgImage)
        #expect(pixels(edited) != pixels(original))
        #expect(edited.width == image.width && edited.height == image.height)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func colorFixture() -> CGImage {
        let width = 240, height = 160
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                data[index] = y < height / 2 ? 220 : 20
                data[index + 1] = 70
                data[index + 2] = y < height / 2 ? 30 : 230
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func pixels(_ image: CGImage) -> Data {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Data(bytes)
    }
}
