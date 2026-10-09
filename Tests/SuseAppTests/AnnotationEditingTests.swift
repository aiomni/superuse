import AppKit
import Testing
@testable import Suse

@Suite(.serialized)
@MainActor
struct AnnotationEditingTests {
    @Test(arguments: [CGFloat(1), 2])
    func selectingRestylingMovingResizingAndDeletingCanEachBeUndone(scale: CGFloat) throws {
        let fixture = try makeFixture(scale: scale)
        defer { fixture.pasteboard.releaseGlobally() }
        let canvas = fixture.canvas
        canvas.tool = .rectangle
        try drag(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 180, y: 120), in: fixture)
        let drawn = pixels(try canvas.renderedImage())
        canvas.tool = .select
        try click(CGPoint(x: 90, y: 70), in: fixture)
        let id = try #require(canvas.selectedID)
        #expect(pixels(try canvas.renderedImage()) == drawn) // Selection chrome never enters export.

        let color = try #require(descendants(fixture.controller.view).first { $0 is NSColorWell } as? NSColorWell)
        color.color = .systemBlue
        color.sendAction(color.action, to: color.target)
        #expect(canvas.selectedAnnotation?.color == .systemBlue)
        let recolored = pixels(try canvas.renderedImage())
        #expect(recolored != drawn)
        canvas.undoEdit()
        #expect(pixels(try canvas.renderedImage()) == drawn)
        canvas.undoEdit(redo: true)
        #expect(pixels(try canvas.renderedImage()) == recolored)

        canvas.setLineWidth(10)
        let thicker = pixels(try canvas.renderedImage())
        #expect(thicker != recolored)
        canvas.undoEdit()
        #expect(canvas.selectedAnnotation?.width == 5)
        canvas.undoEdit(redo: true)
        #expect(canvas.selectedAnnotation?.width == 10)

        try drag(from: CGPoint(x: 90, y: 70), to: CGPoint(x: 130, y: 100), in: fixture)
        #expect(canvas.selectedID == id)
        #expect(canvas.selectedAnnotation?.bounds == CGRect(x: 80, y: 70, width: 140, height: 80))
        canvas.undoEdit()
        #expect(pixels(try canvas.renderedImage()) == thicker)
        canvas.undoEdit(redo: true)
        let moved = pixels(try canvas.renderedImage())
        try drag(from: CGPoint(x: 220, y: 150), to: CGPoint(x: 260, y: 190), in: fixture)
        #expect(canvas.selectedAnnotation?.bounds == CGRect(x: 80, y: 70, width: 180, height: 120))
        canvas.undoEdit()
        #expect(pixels(try canvas.renderedImage()) == moved)
        canvas.undoEdit(redo: true)
        let resized = pixels(try canvas.renderedImage())
        canvas.keyDown(with: try key(code: 51, characters: "\u{7f}", in: fixture))
        #expect(canvas.annotationCount == 0)
        canvas.undoEdit()
        #expect(pixels(try canvas.renderedImage()) == resized)
        #expect(canvas.selectedID == id)
    }

    @Test func topmostHitTestingIgnoresEmptyArrowBoundsAndBlankClicksDoNotMutate() throws {
        let fixture = try makeFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        let canvas = fixture.canvas
        canvas.tool = .rectangle
        try drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 180), in: fixture)
        let rectangleID = try #require(canvas.annotations.first?.id)
        canvas.tool = .arrow
        try drag(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 180, y: 160), in: fixture)
        let arrowID = try #require(canvas.annotations.last?.id)
        canvas.tool = .select
        try click(CGPoint(x: 110, y: 100), in: fixture)
        #expect(canvas.selectedID == arrowID)
        try click(CGPoint(x: 55, y: 145), in: fixture)
        #expect(canvas.selectedID == rectangleID)
        try click(CGPoint(x: 500, y: 350), in: fixture)
        #expect(canvas.selectedID == nil)
        #expect(canvas.annotationCount == 2)
        canvas.undoEdit()
        #expect(canvas.annotationCount == 1) // No undo entries for selection changes.
    }

    @Test func arrowEndpointsAndFreehandBoundsRemainEditable() throws {
        let fixture = try makeFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        let canvas = fixture.canvas
        canvas.tool = .arrow
        try drag(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 180, y: 160), in: fixture)
        canvas.tool = .select
        try click(CGPoint(x: 110, y: 100), in: fixture)
        try drag(from: CGPoint(x: 180, y: 160), to: CGPoint(x: 240, y: 100), in: fixture)
        #expect(canvas.selectedAnnotation?.points == [CGPoint(x: 40, y: 40), CGPoint(x: 240, y: 100)])
        canvas.tool = .pen
        try drag(from: CGPoint(x: 300, y: 40), to: CGPoint(x: 380, y: 120), in: fixture)
        canvas.tool = .select
        try click(CGPoint(x: 340, y: 80), in: fixture)
        #expect(canvas.selectedAnnotation?.tool == .pen)
        try drag(from: CGPoint(x: 380, y: 120), to: CGPoint(x: 420, y: 160), in: fixture)
        #expect(canvas.selectedAnnotation?.bounds == CGRect(x: 300, y: 40, width: 120, height: 120))
    }

    @Test func movingNearCanvasEdgesClampsTheWholeObject() throws {
        let fixture = try makeFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        let canvas = fixture.canvas
        canvas.tool = .ellipse
        try drag(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 180, y: 120), in: fixture)
        canvas.tool = .select
        try drag(from: CGPoint(x: 100, y: 70), to: .zero, in: fixture)
        #expect(canvas.selectedAnnotation?.bounds.origin == .zero)
    }

    @Test(arguments: [CGFloat(1), 2])
    func inlineTextSupportsMultilineEmojiEditingAndNativeTypingUndo(scale: CGFloat) throws {
        let fixture = try makeFixture(scale: scale)
        defer { fixture.pasteboard.releaseGlobally() }
        let canvas = fixture.canvas
        fixture.window.level = .screenSaver
        canvas.tool = .text
        try click(CGPoint(x: 40, y: 40), in: fixture)
        let editor = try #require(canvas.textEditor)
        #expect(fixture.window.attachedSheet == nil)
        #expect(fixture.window.firstResponder === editor)
        #expect(fixture.window.level == .floating)
        #expect(editor.font?.pointSize == 37 / scale)
        editor.insertText("你好 👨‍👩‍👧‍👦 👍🏽\n第二行 🇨🇳", replacementRange: NSRange(location: 0, length: 0))
        #expect(canvas.annotationCount == 1)
        fixture.window.sendEvent(try key(code: 6, characters: "z", modifiers: [.command], in: fixture))
        #expect(editor.string.isEmpty)
        fixture.window.sendEvent(try key(code: 6, characters: "Z", modifiers: [.command, .shift], in: fixture))
        #expect(editor.string == "你好 👨‍👩‍👧‍👦 👍🏽\n第二行 🇨🇳")
        canvas.setInk(.systemBlue)
        canvas.setLineWidth(10)
        #expect(editor.font?.pointSize == 62 / scale)
        #expect(editor.textColor == .systemBlue)
        fixture.window.sendEvent(try key(code: 36, characters: "\r", modifiers: [.command], in: fixture))
        #expect(canvas.textEditor == nil)
        #expect(fixture.window.level == .screenSaver)
        #expect(canvas.annotations.count == 1)
        let initial = try #require(canvas.annotations.first)
        #expect(initial.text == "你好 👨‍👩‍👧‍👦 👍🏽\n第二行 🇨🇳")
        let exported = pixels(try canvas.renderedImage())
        #expect(exported != pixels(canvas.image))

        canvas.tool = .select
        try click(CGPoint(x: 60, y: 60), count: 2, in: fixture)
        let editing = try #require(canvas.textEditor)
        editing.selectAll(nil)
        editing.insertText("修改 ✅", replacementRange: editing.selectedRange())
        canvas.finishTextEditing()
        #expect(canvas.annotations.count == 1)
        #expect(canvas.annotations.first?.id == initial.id)
        #expect(canvas.annotations.first?.text == "修改 ✅")
        canvas.undoEdit()
        #expect(pixels(try canvas.renderedImage()) == exported)
        canvas.undoEdit()
        #expect(canvas.annotationCount == 0)
    }

    @Test func emptyEditsCancelCleanlyAndDeletingExistingTextCanBeUndone() throws {
        let fixture = try makeFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        let canvas = fixture.canvas
        canvas.tool = .text
        try click(CGPoint(x: 40, y: 40), in: fixture)
        canvas.finishTextEditing()
        #expect(canvas.annotations.isEmpty)
        #expect(canvas.undoManager?.canUndo == false)
        canvas.addText("删除这段文字", at: CGPoint(x: 40, y: 40))
        try click(CGPoint(x: 60, y: 60), in: fixture)
        let editor = try #require(canvas.textEditor)
        editor.selectAll(nil)
        editor.insertText("", replacementRange: editor.selectedRange())
        canvas.finishTextEditing()
        #expect(canvas.annotations.isEmpty)
        canvas.undoEdit()
        #expect(canvas.annotations.first?.text == "删除这段文字")
    }

    @Test func emojiToolUsesNativeEditorAndEmojiExportsInColor() throws {
        let fixture = try makeFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        let canvas = fixture.canvas
        var pickerRequests = 0
        canvas.showEmojiPicker = { pickerRequests += 1 }
        canvas.tool = .emoji
        try click(CGPoint(x: 40, y: 40), in: fixture)
        let editor = try #require(canvas.textEditor)
        #expect(pickerRequests == 1)
        editor.insertText("😀", replacementRange: NSRange(location: 0, length: 0))
        let image = try canvas.renderedImage()
        #expect(canvas.annotations.first?.text == "😀")
        let bitmap = NSBitmapImageRep(cgImage: image)
        var yellowPixels = 0
        for y in 40..<100 {
            for x in 40..<100 {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if color.redComponent > 0.6 && color.greenComponent > 0.4 && color.blueComponent < 0.4 { yellowPixels += 1 }
            }
        }
        #expect(yellowPixels > 20)
        canvas.tool = .select
        let annotation = try #require(canvas.annotations.first)
        #expect(annotation.bounds.width < 80)
        try click(CGPoint(x: 60, y: 60), in: fixture)
        let corner = try #require(canvas.selectedAnnotation?.handles.last)
        // Enlarge from the upper-left corner, keeping the opposite corner anchored.
        let start = try #require(canvas.selectedAnnotation?.handles.first)
        try drag(from: start, to: CGPoint(x: start.x - 20, y: start.y - 20), in: fixture)
        #expect(canvas.selectedAnnotation?.fontSize ?? 0 > annotation.fontSize)
        #expect(canvas.selectedAnnotation?.handles.last != corner)
    }

    @Test func nativeTextShortcutsUseAnIsolatedPasteboardAndPreserveComposition() throws {
        let fixture = try makeFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        let canvas = fixture.canvas
        canvas.tool = .text
        try click(CGPoint(x: 40, y: 40), in: fixture)
        let editor = try #require(canvas.textEditor)
        editor.insertText("A👩🏽‍💻B", replacementRange: NSRange(location: 0, length: 0))
        let emoji = (editor.string as NSString).range(of: "👩🏽‍💻")
        editor.setSelectedRange(emoji)
        fixture.window.sendEvent(try key(code: 8, characters: "c", modifiers: [.command], in: fixture))
        #expect(fixture.pasteboard.string(forType: .string) == "👩🏽‍💻")
        fixture.window.sendEvent(try key(code: 7, characters: "x", modifiers: [.command], in: fixture))
        #expect(editor.string == "AB")
        fixture.window.sendEvent(try key(code: 9, characters: "v", modifiers: [.command], in: fixture))
        #expect(editor.string == "A👩🏽‍💻B")
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: editor.selectedRange())
        #expect(editor.hasMarkedText())
        var cancelled = false
        fixture.window.onCancel = { cancelled = true }
        #expect(!fixture.window.performKeyEquivalent(with: try key(code: 53, characters: "\u{1b}", in: fixture)))
        #expect(!cancelled)
        editor.insertText("中", replacementRange: editor.markedRange())
        #expect(!editor.hasMarkedText())
        #expect(editor.string == "A👩🏽‍💻B中")
        fixture.window.sendEvent(try key(code: 53, characters: "\u{1b}", in: fixture))
        #expect(cancelled)
    }

    @Test func copyShortcutCommitsPendingTextAndEnterInsertsANewline() throws {
        let fixture = try makeFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        var completed = false
        fixture.controller.onAction = { if case .done = $0 { completed = true } }
        fixture.canvas.tool = .text
        try click(CGPoint(x: 40, y: 40), in: fixture)
        let editor = try #require(fixture.canvas.textEditor)
        editor.insertText("第一行", replacementRange: NSRange(location: 0, length: 0))
        fixture.window.sendEvent(try key(code: 36, characters: "\r", in: fixture))
        #expect(editor.string == "第一行\n")
        #expect(!completed)
        fixture.window.sendEvent(try key(code: 8, characters: "C", modifiers: [.command, .shift], in: fixture))
        #expect(fixture.canvas.textEditor == nil)
        let png = try #require(fixture.pasteboard.data(forType: .png))
        let image = try #require(NSBitmapImageRep(data: png)?.cgImage)
        #expect(pixels(image) != pixels(fixture.canvas.image))
        #expect(image.width == 640 && image.height == 420)
        #expect(!completed)
    }

    @Test func textHandlesResizeImmediatelyAfterFinishingTyping() throws {
        let fixture = try makeFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        fixture.canvas.tool = .text
        try click(CGPoint(x: 100, y: 100), in: fixture)
        let editor = try #require(fixture.canvas.textEditor)
        editor.insertText("缩放 😀", replacementRange: NSRange(location: 0, length: 0))
        fixture.canvas.finishTextEditing()
        let text = try #require(fixture.canvas.selectedAnnotation)
        let handle = text.handles[2]
        try drag(from: handle, to: CGPoint(x: handle.x + 40, y: handle.y + 40), in: fixture)
        #expect(fixture.canvas.textEditor == nil)
        #expect(fixture.canvas.selectedAnnotation?.fontSize ?? 0 > text.fontSize)
        #expect(fixture.canvas.annotationCount == 1)
    }

    @Test(arguments: [CGFloat(1), 2], [false, true])
    func textSideHandlesReflowWithoutScalingAndSupportUndo(scale: CGFloat, fromLeft: Bool) throws {
        let fixture = try makeFixture(scale: scale)
        defer { fixture.pasteboard.releaseGlobally() }
        let canvas = fixture.canvas
        let text = "独立调整文字宽度，保留字号 👩🏽‍💻\n手动换行也会保留。"
        canvas.addText(text, at: CGPoint(x: 40, y: 40))
        canvas.tool = .select
        try click(CGPoint(x: 80, y: 60), in: fixture)
        let original = try #require(canvas.selectedAnnotation)
        let pixelsBefore = pixels(try canvas.renderedImage())
        let newWidth: CGFloat = 160
        let targetX = fromLeft ? original.textLayoutBounds.maxX - newWidth : original.points[0].x + newWidth
        try dragTextWidth(fromLeft: fromLeft, toX: targetX, in: fixture)
        let resized = try #require(canvas.selectedAnnotation)
        #expect(resized.textWidth == newWidth)
        #expect(resized.fontSize == original.fontSize)
        #expect(resized.text == text)
        #expect(resized.textLayoutBounds.height > original.textLayoutBounds.height)
        #expect(resized.points[0].y == original.points[0].y)
        if fromLeft { #expect(resized.textLayoutBounds.maxX == original.textLayoutBounds.maxX) }
        else { #expect(resized.points[0].x == original.points[0].x) }
        let pixelsAfter = pixels(try canvas.renderedImage())
        #expect(pixelsAfter != pixelsBefore)
        canvas.undoEdit()
        #expect(pixels(try canvas.renderedImage()) == pixelsBefore)
        canvas.undoEdit(redo: true)
        #expect(pixels(try canvas.renderedImage()) == pixelsAfter)
        try dragTextWidth(fromLeft: fromLeft, toX: fromLeft ? resized.textLayoutBounds.maxX - 260 : resized.points[0].x + 260, in: fixture)
        #expect(canvas.selectedAnnotation?.textLayoutBounds.height ?? 0 < resized.textLayoutBounds.height)
    }

    @Test(arguments: [CGFloat(1), 2])
    func liveWidthChangesPreserveTheNativeEditorSelectionAndTypingUndo(scale: CGFloat) throws {
        let fixture = try makeFixture(scale: scale)
        defer { fixture.pasteboard.releaseGlobally() }
        let canvas = fixture.canvas
        canvas.tool = .text
        try click(CGPoint(x: 40, y: 40), in: fixture)
        let editor = try #require(canvas.textEditor)
        editor.insertText("Hello 中文 👨‍👩‍👧‍👦，调整宽度后继续输入。", replacementRange: NSRange(location: 0, length: 0))
        let original = try #require(canvas.selectedAnnotation)
        let selection = (editor.string as NSString).range(of: "👨‍👩‍👧‍👦")
        editor.setSelectedRange(selection)
        try dragTextWidth(fromLeft: false, toX: 240, in: fixture)
        #expect(canvas.textEditor === editor)
        #expect(fixture.window.firstResponder === editor)
        #expect(editor.selectedRange() == selection)
        #expect(editor.frame.width == 200 / scale)
        #expect(editor.font?.pointSize == original.fontSize / scale)
        #expect(canvas.selectedAnnotation?.textWidth == 200)
        #expect(editor.string == original.text)
        canvas.undoEdit()
        #expect(canvas.selectedAnnotation?.textWidth == original.textWidth)
        #expect(editor.string == original.text)
        canvas.undoEdit(redo: true)
        #expect(canvas.selectedAnnotation?.textWidth == 200)
        #expect(editor.string == original.text)
        editor.insertText("✅", replacementRange: selection)
        #expect(editor.string.contains("✅"))
        canvas.finishTextEditing()
        #expect(canvas.annotations.first?.textWidth == 200)
        #expect(canvas.annotations.first?.text.contains("✅") == true)
    }

    @Test func widthResizeKeepsMarkedTextAndCommitsWidthOnlyEdits() throws {
        let fixture = try makeFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        let canvas = fixture.canvas
        canvas.addText("已有文字，调整宽度后保持内容", at: CGPoint(x: 100, y: 40))
        canvas.tool = .text
        try click(CGPoint(x: 120, y: 60), in: fixture)
        let editor = try #require(canvas.textEditor)
        let original = try #require(canvas.selectedAnnotation)
        try dragTextWidth(fromLeft: true, toX: 20, in: fixture)
        #expect(editor.string == original.text)
        let exported = try canvas.renderedImage()
        #expect(exported.width == 640 && exported.height == 420)
        #expect(canvas.annotations.first?.id == original.id)
        #expect(canvas.annotations.first?.textWidth == original.textWidth + 80)
        #expect(canvas.annotations.first?.points[0].x == 20)
        try click(CGPoint(x: 50, y: 60), in: fixture)
        let reopened = try #require(canvas.textEditor)
        #expect(reopened.frame.width == original.textWidth + 80)
        reopened.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: reopened.selectedRange())
        let marked = reopened.markedRange()
        let selection = reopened.selectedRange()
        try dragTextWidth(fromLeft: false, toX: 220, in: fixture)
        #expect(canvas.textEditor === reopened)
        #expect(reopened.hasMarkedText())
        #expect(reopened.markedRange() == marked)
        #expect(reopened.selectedRange() == selection)
        reopened.insertText("中", replacementRange: marked)
        canvas.finishTextEditing()
        #expect(canvas.annotations.first?.text.hasSuffix("中") == true)
        #expect(canvas.annotations.first?.textWidth == 200)
    }

    @Test(arguments: [CGFloat(1), 2])
    func emptyTextWidthCanBeSetBeforeTypingAndResizingClampsToCanvas(scale: CGFloat) throws {
        let fixture = try makeFixture(scale: scale)
        defer { fixture.pasteboard.releaseGlobally() }
        let canvas = fixture.canvas
        canvas.tool = .text
        try click(CGPoint(x: 40, y: 40), in: fixture)
        let editor = try #require(canvas.textEditor)
        try dragTextWidth(fromLeft: false, toX: -100, in: fixture)
        #expect(canvas.selectedAnnotation?.textWidth == 24 * scale)
        #expect(editor.string.isEmpty)
        #expect(canvas.annotationCount == 0)
        try dragTextWidth(fromLeft: false, toX: 900, in: fixture)
        #expect(canvas.selectedAnnotation?.textLayoutBounds.maxX == 640)
        try dragTextWidth(fromLeft: true, toX: -100, in: fixture)
        #expect(canvas.selectedAnnotation?.textLayoutBounds.minX == 0)
        #expect(canvas.selectedAnnotation?.textWidth == 640)
        editor.insertText("输入前就能调整宽度 😀", replacementRange: NSRange(location: 0, length: 0))
        canvas.finishTextEditing()
        #expect(canvas.annotations.first?.textWidth == 640)
    }

    @Test func editingEarlierAnnotationsRebuildsMosaicFromCurrentContent() throws {
        let fixture = try makeFixture()
        let reference = try makeFixture()
        defer { fixture.pasteboard.releaseGlobally(); reference.pasteboard.releaseGlobally() }
        for candidate in [fixture, reference] {
            candidate.canvas.tool = .redact
            let offset: CGFloat = candidate.canvas === reference.canvas ? 20 : 0
            try drag(from: CGPoint(x: 20 + offset, y: 20 + offset), to: CGPoint(x: 180 + offset, y: 180 + offset), in: candidate)
            candidate.canvas.tool = .mosaic
            try drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 240, y: 240), in: candidate)
        }
        fixture.canvas.tool = .select
        try drag(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 60, y: 60), in: fixture)
        #expect(pixels(try fixture.canvas.renderedImage()) == pixels(try reference.canvas.renderedImage()))
        try click(CGPoint(x: 220, y: 220), in: fixture)
        reference.canvas.tool = .select
        try click(CGPoint(x: 220, y: 220), in: reference)
        fixture.canvas.setLineWidth(10)
        reference.canvas.setLineWidth(10)
        #expect(fixture.canvas.selectedAnnotation?.tool == .mosaic)
        #expect(pixels(try fixture.canvas.renderedImage()) == pixels(try reference.canvas.renderedImage()))
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
    func inlineEditorAndSelectionKeepToolbarsAnchored(appearance: NSAppearance.Name) throws {
        let fixture = try makeFixture()
        defer { fixture.pasteboard.releaseGlobally() }
        fixture.window.appearance = NSAppearance(named: appearance)
        fixture.controller.view.layoutSubtreeIfNeeded()
        let canvas = fixture.canvas
        let controls = descendants(fixture.controller.view).compactMap { $0 as? NSGlassEffectView }
        let anchors = controls.map(\.frame)
        canvas.tool = .rectangle
        try drag(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 400, y: 120), in: fixture)
        canvas.tool = .select
        try click(CGPoint(x: 200, y: 80), in: fixture)
        try renderPreview(fixture, named: "annotation-selection-\(appearance.rawValue)")
        canvas.tool = .text
        try click(CGPoint(x: 50, y: 170), in: fixture)
        let editor = try #require(canvas.textEditor)
        editor.insertText("在画布上编辑 👩🏽‍💻\n中文、emoji 与换行 ✅", replacementRange: NSRange(location: 0, length: 0))
        #expect(canvas.bounds.contains(editor.frame))
        #expect(!editor.isRichText && editor.allowsUndo)
        #expect(editor.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ==
                fixture.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]))
        #expect(controls.map(\.frame) == anchors)
        try renderPreview(fixture, named: "annotation-text-\(appearance.rawValue)")
        try dragTextWidth(fromLeft: false, toX: 270, in: fixture)
        #expect(canvas.textEditor === editor)
        #expect(controls.map(\.frame) == anchors)
        try renderPreview(fixture, named: "annotation-width-\(appearance.rawValue)")
        canvas.finishTextEditing()
        #expect(controls.map(\.frame) == anchors)
        try renderPreview(fixture, named: "annotation-finished-\(appearance.rawValue)")
    }

    private struct Fixture {
        let controller: CaptureReviewController
        let window: SelectionWindow
        let canvas: AnnotationCanvas
        let pasteboard: NSPasteboard
        let scale: CGFloat
    }

    private func makeFixture(scale: CGFloat = 1) throws -> Fixture {
        _ = NSApplication.shared
        let context = try #require(CGContext(data: nil, width: 640, height: 420, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 420))
        let image = try #require(context.makeImage())
        let pasteboard = NSPasteboard.withUniqueName()
        let controller = CaptureReviewController(image: image,
                                                 selectionRect: CGRect(x: 200, y: 100, width: 640 / scale, height: 420 / scale),
                                                 displaySize: CGSize(width: 1200, height: 800), allowsScrolling: true,
                                                 pasteboard: pasteboard)
        let window = SelectionWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
                                     styleMask: .borderless, backing: .buffered, defer: false)
        window.contentViewController = controller
        window.handleReviewKey = { [weak controller] in controller?.view.performKeyEquivalent(with: $0) ?? false }
        let canvas = try #require(descendants(controller.view).first { $0 is AnnotationCanvas } as? AnnotationCanvas)
        return Fixture(controller: controller, window: window, canvas: canvas, pasteboard: pasteboard, scale: scale)
    }

    private func click(_ point: CGPoint, count: Int = 1, in fixture: Fixture) throws {
        fixture.canvas.mouseDown(with: try mouse(.leftMouseDown, point: point, count: count, in: fixture))
        fixture.canvas.mouseUp(with: try mouse(.leftMouseUp, point: point, count: count, in: fixture))
    }

    private func drag(from start: CGPoint, to end: CGPoint, in fixture: Fixture) throws {
        fixture.canvas.mouseDown(with: try mouse(.leftMouseDown, point: start, in: fixture))
        fixture.canvas.mouseDragged(with: try mouse(.leftMouseDragged,
                                                    point: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2), in: fixture))
        fixture.canvas.mouseUp(with: try mouse(.leftMouseUp, point: end, in: fixture))
    }

    private func dragTextWidth(fromLeft: Bool, toX x: CGFloat, in fixture: Fixture) throws {
        // AppKit closes automatic typing undo groups between keyboard and mouse events.
        // Synthetic direct dispatch must also allow that run-loop checkpoint.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        let handle = try #require(descendants(fixture.canvas).compactMap { $0 as? AnnotationTextWidthHandle }
            .first { $0.fromLeft == fromLeft })
        #expect(!handle.isHidden)
        let edge = try #require(fixture.canvas.selectedAnnotation?.handles[fromLeft ? 4 : 5])
        let local = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: fixture.canvas)
        let start = CGPoint(x: local.x * fixture.scale, y: local.y * fixture.scale)
        let end = CGPoint(x: x + start.x - edge.x, y: start.y)
        let hitPoint = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: fixture.canvas.superview)
        #expect(fixture.canvas.hitTest(hitPoint) === handle)
        handle.mouseDown(with: try mouse(.leftMouseDown, point: start, in: fixture))
        handle.mouseDragged(with: try mouse(.leftMouseDragged, point: CGPoint(x: (start.x + end.x) / 2, y: start.y), in: fixture))
        handle.mouseUp(with: try mouse(.leftMouseUp, point: end, in: fixture))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    private func mouse(_ type: NSEvent.EventType, point: CGPoint, count: Int = 1, in fixture: Fixture) throws -> NSEvent {
        let local = CGPoint(x: point.x / fixture.scale, y: point.y / fixture.scale)
        return try #require(NSEvent.mouseEvent(with: type, location: fixture.canvas.convert(local, to: nil), modifierFlags: [],
                                              timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: count, pressure: 1))
    }

    private func key(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = [], in fixture: Fixture) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                     windowNumber: fixture.window.windowNumber, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    private func renderPreview(_ fixture: Fixture, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SUSE_UI_PREVIEW_DIRECTORY"] else { return }
        let view = fixture.controller.view
        let tools = descendants(view).compactMap { $0 as? NSSegmentedControl }
            .first { $0.segmentCount == AnnotationTool.allCases.count }
        tools?.selectedSegment = fixture.canvas.tool.rawValue
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        fixture.window.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent("\(name).png"))
    }

    private func pixels(_ image: CGImage) -> Data {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }
}
