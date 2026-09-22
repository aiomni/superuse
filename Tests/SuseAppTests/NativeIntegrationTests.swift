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
        let editor = AnnotationWindowController(image: colorFixture())
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(editor.window?.contentView != nil)
        let (store, settings, pasteboard, _, suite) = isolatedStore()
        defer { settings.defaults.removePersistentDomain(forName: suite); pasteboard.releaseGlobally() }
        let panel = ClipboardPanelController(store: store)
        panel.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(panel.window?.contentView is NSGlassEffectView)
        let glass = try #require(panel.window?.contentView as? NSGlassEffectView)
        let content = try #require(glass.contentView)
        #expect(content.fittingSize.height <= glass.bounds.height)
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
