import AppKit
import ImageIO
import Testing
import SuseCore
@testable import Suse

@MainActor
private final class PinServiceDouble: PinPresenting {
    var requests: [PinRequest] = []
    var failure: Error?
    var suspensions: [UUID] = []
    var resumptions: [UUID] = []
    func pin(_ request: PinRequest) throws {
        if let failure { throw failure }
        requests.append(request)
    }
    func suspendForCapture() -> UUID { let id = UUID(); suspensions.append(id); return id }
    func resumeAfterCapture(_ token: UUID) { resumptions.append(token) }
    func closeClipboardPins(entryID: UUID?) { }
}

@Suite(.serialized)
@MainActor
struct PinTests {
    @Test func captureSuppressionPreservesHiddenStateAndSupportsNestedCancellation() throws {
        let store = PinStore()
        let first = try store.insert(PinRequest(content: .text("first"), source: .screenshot))
        store.toggleVisibility()
        let outer = store.suspendForCapture(), inner = store.suspendForCapture()
        let second = try store.insert(PinRequest(content: .text("second"), source: .screenshot))
        #expect(store.items.allSatisfy { !store.isVisible($0) })
        store.resumeAfterCapture(inner)
        store.resumeAfterCapture(inner)
        #expect(store.isCapturing)
        store.resumeAfterCapture(outer)
        #expect(!store.isVisible(try #require(store.items.first { $0.id == first })))
        #expect(store.isVisible(try #require(store.items.first { $0.id == second })))
        store.setClickThrough(true, for: second)
        let next = store.suspendForCapture()
        store.restoreInteraction()
        #expect(store.items.allSatisfy { !store.isVisible($0) && !$0.isClickThrough })
        store.remove(second)
        store.resumeAfterCapture(next)
        #expect(store.items.map(\.id) == [first])
        #expect(store.isVisible(try #require(store.items.first)))
    }

    @Test func budgetsRejectNewPinsWithoutEvictingExistingContent() throws {
        let store = PinStore(limits: PinResourceLimits(count: 2, bytes: 24))
        let first = try store.insert(PinRequest(content: .text("abcd"), source: .screenshot))
        try store.insert(PinRequest(content: .text("efgh"), source: .screenshot))
        #expect(store.byteCount == 24)
        #expect(throws: (any Error).self) { try store.insert(PinRequest(content: .text("x"), source: .screenshot)) }
        #expect(store.items.count == 2)
        store.remove(first)
        #expect(throws: (any Error).self) { try store.insert(PinRequest(content: .text("too large"), source: .screenshot)) }
        #expect(store.items.count == 1)
        store.removeAll()
        #expect(store.byteCount == 0)
        #expect(throws: (any Error).self) { try store.insert(PinRequest(content: .text(""), source: .screenshot)) }
    }

    @Test func editingReplacesItsAllocationAtTheWindowLimitAndAllowsAnEmptyNote() throws {
        let store = PinStore(limits: PinResourceLimits(count: 2, bytes: 24))
        let first = try store.insert(PinRequest(content: .text("abcd"), source: .clipboard(UUID())))
        try store.insert(PinRequest(content: .text("efgh"), source: .screenshot))
        try store.updateText("你好", for: first)
        #expect(store.byteCount == 22)
        #expect(throws: (any Error).self) { try store.updateText("too long", for: first) }
        #expect(store.byteCount == 22)
        try store.updateText("", for: first)
        #expect(store.byteCount == 12)
        #expect(store.items.count == 2)
        #expect(store.items.first?.title == "文字 · 空白")
        store.remove(first)
        #expect(throws: (any Error).self) { try store.updateText("closed", for: first) }
    }

    @Test func textEditingCopiesTheCurrentValueAndSupportsIndependentUndoRedo() throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("untouched", forType: .string)
        let changeCount = pasteboard.changeCount
        let pins = PinsModule(pasteboard: pasteboard, showsWindows: false)
        defer { pins.stop() }
        try pins.pin(PinRequest(content: .text("first"), source: .clipboard(UUID())))
        let item = try #require(pins.store.items.first)
        let controller = try #require(pins.controllers[item.id])
        let window = try #require(controller.window)
        let text = try #require(controller.textView)
        let undo = try #require(text.undoManager)
        undo.groupsByEvent = false
        window.makeFirstResponder(text)
        undo.beginUndoGrouping()
        text.insertText("你好 👋\nnext", replacementRange: NSRange(location: 0, length: 5))
        text.breakUndoCoalescing()
        undo.endUndoGrouping()
        #expect(pins.store.items.first?.title.contains("你好 👋 next") == true)
        #expect(pasteboard.changeCount == changeCount)
        #expect(controller.copyAll())
        #expect(pasteboard.string(forType: .string) == "你好 👋\nnext")
        window.sendEvent(try key(in: window, code: 6, characters: "z"))
        #expect(text.string == "first")
        #expect(pins.store.items.first?.title == "文字 · first")
        window.sendEvent(try key(in: window, code: 6, characters: "Z", modifiers: [.command, .shift]))
        #expect(text.string == "你好 👋\nnext")
        let caret = text.selectedRange()
        pins.store.setOpacity(0.8, for: item.id)
        let token = pins.suspendForCapture()
        pins.resumeAfterCapture(token)
        #expect(text.selectedRange() == caret)
        #expect(undo.canUndo)
        #expect(controller.copyAll())
        #expect(pasteboard.string(forType: .string) == text.string)
        text.setSelectedRange((text.string as NSString).range(of: "next"))
        text.copy(nil)
        #expect(pasteboard.string(forType: .string) == "next")
    }

    @Test func pastedTextIsPlainAndOverBudgetEditsKeepTheLastAcceptedText() throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let pins = PinsModule(store: PinStore(limits: PinResourceLimits(count: 2, bytes: 30)),
                              pasteboard: pasteboard, showsWindows: false)
        defer { pins.stop() }
        try pins.pin(PinRequest(content: .text("first"), source: .screenshot))
        let controller = try #require(pins.controllers.values.first)
        let text = try #require(controller.textView)
        text.setSelectedRange(NSRange(location: 0, length: 5))
        pasteboard.setString("pasted", forType: .string)
        text.paste(nil)
        #expect(text.string == "pasted")
        #expect(!text.isRichText)
        #expect(pins.store.byteCount == 18)
        text.setSelectedRange(NSRange(location: 1, length: 2))
        let selection = text.selectedRange()
        pasteboard.clearContents()
        pasteboard.setString(String(repeating: "界", count: 20), forType: .string)
        let changeCount = pasteboard.changeCount
        text.paste(nil)
        #expect(text.string == "pasted")
        #expect(text.selectedRange() == selection)
        #expect(pins.store.byteCount == 18)
        #expect(pasteboard.changeCount == changeCount)
        let content = try #require(controller.window?.contentView)
        let status = try #require(descendants(content)
            .first { $0.accessibilityIdentifier() == "pin-edit-status" } as? NSTextField)
        #expect(status.stringValue.contains("内存已达上限"))
        #expect(!status.isHiddenOrHasHiddenAncestor)
        text.insertText("", replacementRange: NSRange(location: 0, length: 6))
        #expect(text.string.isEmpty && pins.store.byteCount == 0)
        #expect(pins.store.items.count == 1)
    }

    @Test func inputMethodCompositionSurvivesWindowStateUpdates() throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let pins = PinsModule(pasteboard: pasteboard, showsWindows: false)
        defer { pins.stop() }
        try pins.pin(PinRequest(content: .text("first"), source: .screenshot))
        let item = try #require(pins.store.items.first)
        let controller = try #require(pins.controllers[item.id])
        let text = try #require(controller.textView)
        controller.window?.makeFirstResponder(text)
        text.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: 0, length: 5))
        #expect(text.hasMarkedText())
        pins.store.setOpacity(0.8, for: item.id)
        #expect(text.hasMarkedText())
        text.insertText("你好", replacementRange: text.markedRange())
        #expect(!text.hasMarkedText())
        #expect(text.string == "你好")
        #expect(pins.store.items.first?.title == "文字 · 你好")
    }

    @Test func undoCannotExceedABudgetConsumedByAnotherPin() throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let pins = PinsModule(store: PinStore(limits: PinResourceLimits(bytes: 18)),
                              pasteboard: pasteboard, showsWindows: false)
        defer { pins.stop() }
        try pins.pin(PinRequest(content: .text("abcdef"), source: .screenshot))
        let controller = try #require(pins.controllers.values.first)
        let text = try #require(controller.textView)
        let undo = try #require(text.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        text.insertText("a", replacementRange: NSRange(location: 0, length: 6))
        text.breakUndoCoalescing()
        undo.endUndoGrouping()
        try pins.pin(PinRequest(content: .text("12345"), source: .screenshot))
        undo.undo()
        #expect(text.string == "a")
        #expect(pins.store.byteCount == 18)
        #expect(pins.store.items.count == 2)
    }

    @Test func imageSnapshotsDetachCropsAndRejectInvalidDataBeforeInsertion() throws {
        let image = try fixture(width: 200, height: 100)
        let crop = try #require(image.cropping(to: CGRect(x: 0, y: 0, width: 40, height: 30)))
        let store = PinStore(limits: PinResourceLimits(bytes: 40 * 30 * 4))
        try store.insert(PinRequest(content: .image(crop, pointSize: CGSize(width: 20, height: 15)), source: .screenshot))
        guard case .image(let snapshot, let size) = try #require(store.items.first).content else {
            Issue.record("Expected an image snapshot"); return
        }
        #expect(snapshot !== crop)
        #expect(snapshot.width == 40 && snapshot.height == 30)
        #expect(size == CGSize(width: 20, height: 15))
        #expect(store.byteCount == 40 * 30 * 4)
        #expect(pixels(snapshot) == pixels(crop))
        store.removeAll()
        #expect(throws: (any Error).self) {
            try store.insert(PinRequest(content: .imageData(Data([1, 2, 3]), scale: 2), source: .screenshot))
        }
        #expect(store.items.isEmpty)
        let smallLimit = PinStore(limits: PinResourceLimits(imagePixels: 5))
        #expect(throws: (any Error).self) {
            try smallLimit.insert(PinRequest(content: .image(image, pointSize: CGSize(width: 200, height: 100)), source: .screenshot))
        }
    }

    @Test(arguments: [false, true])
    func screenshotPinIncludesAnnotationsAndLeavesPasteboardAlone(usingKeyboard: Bool) throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("unchanged", forType: .string)
        let changeCount = pasteboard.changeCount
        let image = try fixture(width: 240, height: 160)
        var pinned: CGImage?
        let controller = CaptureReviewController(image: image, selectionRect: CGRect(x: 100, y: 100, width: 120, height: 80),
                                                 displaySize: CGSize(width: 1200, height: 800), allowsScrolling: false,
                                                 pasteboard: pasteboard, onPin: { pinned = $0 })
        let window = SelectionWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: .borderless,
                                     backing: .buffered, defer: false)
        window.contentViewController = controller
        window.handleReviewKey = { controller.view.performKeyEquivalent(with: $0) }
        let canvas = try #require(descendants(controller.view).first { $0 is AnnotationCanvas } as? AnnotationCanvas)
        canvas.addText("Pin", at: CGPoint(x: 10, y: 10))
        let expected = try canvas.renderedImage()
        var completed = false
        controller.onAction = { if case .pinned = $0 { completed = true } }
        if usingKeyboard {
            window.makeFirstResponder(canvas)
            window.sendEvent(try key(in: window, code: 35, characters: "p"))
        } else {
            let button = try #require(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Pin" })
            button.performClick(nil)
        }
        #expect(completed)
        let result = try #require(pinned)
        #expect(result.width == 240 && result.height == 160)
        #expect(pixels(result) == pixels(expected))
        #expect(pixels(result) != pixels(image))
        #expect(pasteboard.changeCount == changeCount)
        #expect(pasteboard.string(forType: .string) == "unchanged")
    }

    @Test func failedScreenshotPinKeepsEditingAndReportsTheError() throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let controller = CaptureReviewController(image: try fixture(), selectionRect: CGRect(x: 100, y: 100, width: 240, height: 160),
                                                 displaySize: CGSize(width: 1200, height: 800), allowsScrolling: true,
                                                 pasteboard: pasteboard, onPin: { _ in throw AppError("资源不足") })
        var completed = false
        controller.onAction = { _ in completed = true }
        let canvas = try #require(descendants(controller.view).first { $0 is AnnotationCanvas } as? AnnotationCanvas)
        canvas.addText("keep", at: CGPoint(x: 10, y: 10))
        controller.pinImage()
        #expect(!completed)
        #expect(canvas.annotationCount == 1)
        let status = try #require(descendants(controller.view).first { $0.accessibilityIdentifier() == "capture-status" } as? NSTextField)
        #expect(status.stringValue.contains("Pin 失败"))
    }

    @Test func cancellingScreenshotBeforeCaptureRestoresPinsWithoutRequestingPermission() async throws {
        let suite = "app.suse.pin-tests.\(UUID().uuidString)"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        defer { settings.defaults.removePersistentDomain(forName: suite) }
        let service = PinServiceDouble()
        let module = ScreenshotModule(settings: settings, pins: service)
        module.commands[0].perform()
        module.stop()
        for _ in 0..<30 where service.resumptions.isEmpty { await Task.yield() }
        #expect(service.suspensions.count == 1)
        #expect(service.resumptions == service.suspensions)
    }

    @Test func clipboardPinUsesSelectedSnapshotWithoutCopyingOrRemovingIt() throws {
        _ = NSApplication.shared
        let suite = "app.suse.pin-tests.\(UUID().uuidString)"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { settings.defaults.removePersistentDomain(forName: suite); pasteboard.releaseGlobally() }
        let store = ClipboardStore(settings: settings, pasteboard: pasteboard,
                                   persistenceURL: FileManager.default.temporaryDirectory.appending(path: "\(suite)/history.json"))
        pasteboard.clearContents()
        pasteboard.setString("line 1\n    line 2", forType: .string)
        store.checkForChanges()
        let entry = try #require(store.history.entries.first)
        let pins = PinServiceDouble()
        let panel = ClipboardPanelController(store: store, pins: pins)
        pasteboard.clearContents()
        pasteboard.setString("new clipboard", forType: .string)
        let changeCount = pasteboard.changeCount
        panel.pinSelected()
        let request = try #require(pins.requests.first)
        #expect(request.source == .clipboard(entry.id))
        guard case .text(let text) = request.content else { Issue.record("Expected text"); return }
        #expect(text == "line 1\n    line 2")
        #expect(store.history.entries == [entry])
        #expect(pasteboard.changeCount == changeCount)
        pins.failure = AppError("Pin capacity")
        panel.pinSelected()
        #expect(pins.requests.count == 1)
        #expect(descendants(try #require(panel.window?.contentView)).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue.contains("Pin 失败") })
    }

    @Test func historyEditingAndEvictionKeepSnapshotsWhileExplicitDeletionClosesThem() throws {
        _ = NSApplication.shared
        let suite = "app.suse.pin-tests.\(UUID().uuidString)"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        settings.defaults.set(1, forKey: "clipboard.limit")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { settings.defaults.removePersistentDomain(forName: suite); pasteboard.releaseGlobally() }
        let store = ClipboardStore(settings: settings, pasteboard: pasteboard,
                                   persistenceURL: FileManager.default.temporaryDirectory.appending(path: "\(suite)/history.json"))
        let pins = PinsModule(pasteboard: pasteboard, showsWindows: false)
        defer { pins.stop() }
        let module = ClipboardModule(settings: settings, pins: pins, store: store)
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        store.checkForChanges()
        let entry = try #require(store.history.entries.first)
        try pins.pin(PinRequest(content: .text("original"), source: .clipboard(entry.id)))
        try pins.pin(PinRequest(content: .text("screenshot reference"), source: .screenshot))
        let pinned = try #require(pins.store.items.first)
        let editor = try #require(pins.controllers[pinned.id]?.textView)
        editor.insertText("pin notes", replacementRange: NSRange(location: 0, length: 8))
        #expect(store.history.entries.first == entry)
        #expect(store.edit(entry, text: "edited"))
        pasteboard.clearContents()
        pasteboard.setString("new entry", forType: .string)
        store.checkForChanges()
        #expect(store.history.entries.count == 1)
        #expect(pins.store.items.count == 2)
        guard case .text(let text) = try #require(pins.store.items.first).content else { Issue.record("Expected text"); return }
        #expect(text == "pin notes")
        store.remove(entry)
        #expect(pins.store.items.map(\.source) == [.screenshot])
        try pins.pin(PinRequest(content: .text("another"), source: .clipboard(UUID())))
        let clear = try #require(descendants(module.makeSettingsView()).compactMap { $0 as? NSButton }.first { $0.title == "清空全部历史" })
        clear.performClick(nil)
        #expect(pins.store.items.map(\.source) == [.screenshot])
    }

    @Test func nativePinSupportsCopySelectionOpacityRecoveryAndCleanup() throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let pins = PinsModule(pasteboard: pasteboard, showsWindows: false)
        defer { pins.stop() }
        try pins.pin(PinRequest(content: .text("first\nsecond"), source: .screenshot))
        let item = try #require(pins.store.items.first)
        let controller = try #require(pins.controllers[item.id])
        let window = try #require(controller.window)
        #expect(window is PinPanel)
        #expect(window.level == .floating)
        #expect(window.styleMask.contains(.nonactivatingPanel))
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!window.canBecomeMain)
        #expect(!window.isVisible)
        let text = try #require(controller.textView)
        #expect(text.isEditable && text.isSelectable)
        window.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: 6, length: 6))
        window.sendEvent(try key(in: window, code: 8, characters: "c"))
        #expect(pasteboard.string(forType: .string) == "second")
        #expect(controller.copyAll())
        #expect(pasteboard.string(forType: .string) == "first\nsecond")
        pins.store.setOpacity(0.1, for: item.id)
        #expect(window.alphaValue == 0.3)
        pins.store.setClickThrough(true, for: item.id)
        #expect(window.ignoresMouseEvents)
        let menu = pins.makeMenu()
        let restore = try #require(menu.items.first { $0.title == "恢复全部操作" })
        NSApp.sendAction(try #require(restore.action), to: restore.target, from: restore)
        #expect(!window.ignoresMouseEvents)
        window.sendEvent(try key(in: window, code: 13, characters: "w"))
        #expect(pins.store.items.isEmpty)
        #expect(pins.controllers.isEmpty)
        #expect(pins.store.byteCount == 0)
    }

    @Test func imageCopyPreservesFullPixelsAfterZoomAndTransparencyChanges() throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let pins = PinsModule(pasteboard: pasteboard, showsWindows: false)
        defer { pins.stop() }
        let image = try fixture()
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try pins.pin(PinRequest(content: .imageData(data, scale: 2), source: .clipboard(UUID())))
        let item = try #require(pins.store.items.first)
        let controller = try #require(pins.controllers[item.id])
        controller.setImageScale(0.5)
        pins.store.setOpacity(0.4, for: item.id)
        #expect(controller.copyAll())
        let copied = try #require(pasteboard.data(forType: .png))
        let source = try #require(CGImageSourceCreateWithData(copied as CFData, nil))
        let result = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(result.width == image.width && result.height == image.height)
        #expect(pixels(result) == pixels(image))
    }

    @Test func nativeToolbarZoomCopyAndOptionsUseTheSamePinActions() throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let pins = PinsModule(pasteboard: pasteboard, showsWindows: false)
        defer { pins.stop() }
        try pins.pin(PinRequest(content: .image(try fixture(), pointSize: CGSize(width: 400, height: 260)), source: .screenshot))
        let item = try #require(pins.store.items.first)
        let controller = try #require(pins.controllers[item.id])
        let window = try #require(controller.window)
        let toolbar = try #require(window.toolbar)
        let group = try #require(toolbar.items.compactMap { $0 as? NSToolbarItemGroup }.first)
        let before = window.frame.width
        group.selectedIndex = 2
        NSApp.sendAction(try #require(group.action), to: group.target, from: group)
        #expect(window.frame.width > before)
        let copy = try #require(toolbar.items.first { $0.itemIdentifier.rawValue == "pin.copy" })
        NSApp.sendAction(try #require(copy.action), to: copy.target, from: copy)
        #expect(pasteboard.data(forType: .png) != nil)
        let options = try #require(toolbar.items.compactMap { $0 as? NSMenuToolbarItem }.first)
        controller.menuNeedsUpdate(options.menu)
        let through = try #require(options.menu.items.first { $0.title == "鼠标穿透" })
        NSApp.sendAction(try #require(through.action), to: through.target, from: through)
        #expect(window.ignoresMouseEvents)
        controller.menuNeedsUpdate(options.menu)
        #expect(options.menu.items.first { $0.title == "鼠标穿透" }?.state == .on)
    }

    @Test func managementMenuDoesNotRetainClosedSnapshotsAndStopClearsCaptureState() throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let pins = PinsModule(pasteboard: pasteboard, showsWindows: false)
        weak var snapshot: CGImage?
        let menu = try autoreleasepool {
            try pins.pin(PinRequest(content: .image(try fixture(), pointSize: CGSize(width: 120, height: 80)), source: .screenshot))
            guard case .image(let image, _) = try #require(pins.store.items.first).content else {
                Issue.record("Expected image"); return NSMenu()
            }
            snapshot = image
            return pins.makeMenu()
        }
        #expect(snapshot != nil)
        let close = try #require(menu.items.first { $0.title == "关闭全部 Pin" })
        _ = try autoreleasepool { NSApp.sendAction(try #require(close.action), to: close.target, from: close) }
        #expect(snapshot == nil)
        #expect(pins.controllers.isEmpty)
        let token = pins.suspendForCapture()
        pins.stop()
        #expect(!pins.store.isCapturing)
        pins.resumeAfterCapture(token)
        #expect(pins.store.items.isEmpty)
    }

    @Test func pinManagementShortcutStartsUnassignedAndHonorsSavedPreferences() throws {
        let suite = "app.suse.pin-tests.\(UUID().uuidString)"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        defer { settings.defaults.removePersistentDomain(forName: suite) }
        let module = PinsModule(showsWindows: false)
        let command = try #require(module.commands.first)
        let hub = ShortcutHub(settings: settings)
        #expect(hub.shortcut(for: command) == nil)
        let custom = Shortcut(keyCode: 35)
        settings.save(shortcut: custom, for: command.id)
        #expect(hub.shortcut(for: command) == custom)
        settings.setShortcutDisabled(true, for: command.id)
        #expect(hub.shortcut(for: command) == nil)
    }

    private func fixture(width: Int = 240, height: Int = 160) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                           bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        return try #require(context.makeImage())
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let pointer = bitmap.bitmapData else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: bitmap.bytesPerRow * bitmap.pixelsHigh))
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    private func key(in window: NSWindow, code: UInt16, characters: String,
                     modifiers: NSEvent.ModifierFlags = [.command]) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
}
