import AppKit
import Testing
import SuseCore
@testable import Suse

/// Exercises actual AppKit layout without opening windows or changing system appearance.
@Suite(.serialized)
@MainActor
struct InterfaceLayoutTests {
    private let appearances: [(String, NSAppearance.Name)] = [
        ("light", .aqua), ("dark", .darkAqua),
        ("contrast-light", .accessibilityHighContrastAqua),
        ("contrast-dark", .accessibilityHighContrastDarkAqua),
    ]

    @Test func dashboardAndSettingsFitTheirWindowsAcrossAppearances() throws {
        _ = NSApplication.shared
        let suite = "app.suse.layout.\(UUID().uuidString)"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        defer { settings.defaults.removePersistentDomain(forName: suite) }
        let features: [any FeatureModule] = [ScreenshotModule(settings: settings), ClipboardModule(settings: settings)]
        let hub = ShortcutHub(settings: settings)
        let dashboard = DashboardWindowController(features: features, hub: hub, openSettings: {})
        let preferences = SettingsWindowController(features: features, hub: hub)
        for (name, appearance) in appearances {
            let window = try #require(dashboard.window)
            window.appearance = NSAppearance(named: appearance)
            let content = try #require(window.contentView)
            content.layoutSubtreeIfNeeded()
            for section in descendants(content).compactMap({ $0 as? NSBox }) {
                #expect(content.bounds.contains(content.convert(section.bounds, from: section)))
            }
            try render(window, named: "toolbox-\(name)")
            let settingsWindow = try #require(preferences.window)
            settingsWindow.appearance = NSAppearance(named: appearance)
            settingsWindow.setContentSize(CGSize(width: 740, height: 510))
            let settingsContent = try #require(settingsWindow.contentView)
            let sidebar = try #require(descendants(settingsContent).first { $0 is NSTableView } as? NSTableView)
            for row in [0, 2, 3] {
                sidebar.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                settingsContent.layoutSubtreeIfNeeded()
                let page = try #require(descendants(settingsContent).compactMap { $0 as? NSScrollView }
                    .first { $0.documentView is FlippedView })
                let document = try #require(page.documentView)
                #expect(abs(document.frame.width - page.contentView.bounds.width) < 1)
                #expect(document.frame.height > 100)
                #expect(!descendants(document).contains { $0 is NSGlassEffectView })
                try render(settingsWindow, named: "settings-\(row)-\(name)")
            }
        }
    }

    @Test func clipboardListRemainsCompactWithGlassOnlyInControls() throws {
        _ = NSApplication.shared
        let suite = "app.suse.layout.\(UUID().uuidString)"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { settings.defaults.removePersistentDomain(forName: suite); pasteboard.releaseGlobally() }
        let store = ClipboardStore(settings: settings, pasteboard: pasteboard)
        for text in ["随手记录一个想法", "一个快捷键，自动选择屏幕和窗口。", "原生界面，紧凑布局。",
                     "保留内容的清晰度，让操作控件浮在上方。", "可以用方向键选择历史内容。", "superuse · 截图与剪贴板"] {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            store.checkForChanges()
        }
        let controller = ClipboardPanelController(store: store)
        let window = try #require(controller.window)
        for (name, appearance) in appearances {
            window.appearance = NSAppearance(named: appearance)
            let content = try #require(window.contentView)
            content.layoutSubtreeIfNeeded()
            let table = try #require(descendants(content).first { $0 is NSTableView } as? NSTableView)
            #expect(table.numberOfRows == 6)
            #expect(table.rowHeight == 58)
            let scroll = try #require(table.enclosingScrollView)
            #expect(scroll.frame.height >= 290)
            #expect(content.bounds.contains(content.convert(scroll.bounds, from: scroll)))
            #expect(window.toolbar?.items.contains { $0 is NSSearchToolbarItem } == true)
            try render(window, named: "clipboard-\(name)")
        }
    }

    @Test func screenshotControlsShareGlassWithoutCoveringTheImage() throws {
        _ = NSApplication.shared
        let size = CGSize(width: 1200, height: 800)
        let selection = CGRect(x: 260, y: 120, width: 680, height: 440)
        let image = screenshotFixture(size: size)
        let region = ScreenGeometry.pixelCrop(selection: selection, displayFrame: CGRect(origin: .zero, size: size),
                                              pixelSize: CGSize(width: image.width, height: image.height))
        let crop = try #require(image.cropping(to: region))
        for (name, appearance) in appearances {
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            let background = NSImageView(image: NSImage(cgImage: image, size: size))
            background.frame = CGRect(origin: .zero, size: size)
            background.imageScaling = .scaleAxesIndependently
            window.contentView = background
            let controller = CaptureReviewController(image: crop, selectionRect: selection, displaySize: size, allowsScrolling: true)
            background.addSubview(controller.view)
            controller.view.frame = background.bounds
            let container = try #require(controller.view.subviews.first { $0 is NSGlassEffectContainerView })
            let canvas = try #require(descendants(controller.view).first { $0 is AnnotationCanvas })
            #expect(!canvas.isDescendant(of: container))
            #expect(controller.view.bounds.contains(container.frame))
            #expect(!selection.intersects(container.frame))
            try render(window, named: "capture-\(name)")
            let complete = try #require(descendants(container).compactMap { $0 as? NSButton }.first { $0.title == "完成" })
            controller.view.layoutSubtreeIfNeeded()
            let mainBar = try #require(descendants(container).compactMap { $0 as? NSGlassEffectView }
                .first { complete.isDescendant(of: $0) })
            let buttons = descendants(mainBar).compactMap { $0 as? NSButton }
            // Main actions remain a single compact row with equal click targets.
            let frames = buttons.map { mainBar.convert($0.bounds, from: $0) }
            #expect(mainBar.frame.height <= 52)
            #expect(frames.allSatisfy { abs($0.midY - frames[0].midY) < 1 && $0.height >= 32 })
            #expect(!descendants(mainBar).contains { $0 is NSTextField })
            let status = try #require(descendants(controller.view).first {
                $0.accessibilityIdentifier() == "capture-status"
            })
            #expect(!status.isDescendant(of: container))
            #expect(controller.view.bounds.contains(controller.view.convert(status.bounds, from: status)))
            let expectedAppearance: NSAppearance.Name = name.hasPrefix("contrast-") ? .accessibilityHighContrastDarkAqua : .darkAqua
            // Recent AppKit versions resolve contrast names to the base appearance
            // and apply the system accessibility setting during rendering.
            #expect(container.effectiveAppearance.name == NSAppearance(named: expectedAppearance)?.name)
            try expectCompactImageTitleSpacing(complete)
            let palette = try #require(descendants(container).compactMap { $0 as? NSGlassEffectView }
                .first { $0 !== mainBar })
            #expect(!palette.isHiddenOrHasHiddenAncestor)
            #expect(!controller.view.convert(palette.bounds, from: palette)
                .intersects(controller.view.convert(mainBar.bounds, from: mainBar)))
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func expectCompactImageTitleSpacing(_ button: NSButton) throws {
        let cell = try #require(button.cell as? NSButtonCell)
        let imageRect = cell.imageRect(forBounds: button.bounds)
        let titleRect = cell.titleRect(forBounds: button.bounds)
        // The centered text can be narrower than the space allocated by the cell.
        let textWidth = button.attributedTitle.size().width
        let gap = titleRect.midX - textWidth / 2 - imageRect.maxX
        #expect(gap >= 0 && gap <= 6)
    }

    private func screenshotFixture(size: CGSize) -> CGImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedRed: 0.18, green: 0.29, blue: 0.42, alpha: 1).setFill()
        CGRect(origin: .zero, size: size).fill()
        NSColor.white.setFill()
        CGRect(x: 260, y: 240, width: 680, height: 440).fill()
        ("superuse 截图交互" as NSString).draw(at: CGPoint(x: 290, y: 620), withAttributes: [
            .font: NSFont.systemFont(ofSize: 25, weight: .semibold), .foregroundColor: NSColor.black,
        ])
        for row in 0..<9 {
            ("\(row + 1). 单击确认目标，拖动选择区域，原位编辑截图。" as NSString).draw(
                at: CGPoint(x: 290, y: 575 - row * 30),
                withAttributes: [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.darkGray])
        }
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    private func render(_ window: NSWindow, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SUSE_UI_PREVIEW_DIRECTORY"] else { return }
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent("\(name).png"))
    }
}
