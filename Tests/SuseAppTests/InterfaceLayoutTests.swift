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
        let pins = PinsModule(showsWindows: false)
        let features: [any FeatureModule] = [ScreenshotModule(settings: settings, pins: pins), ClipboardModule(settings: settings, pins: pins), pins, SystemMonitorModule(settings: settings, showsUI: false)]
        let hub = ShortcutHub(settings: settings)
        let dashboard = DashboardWindowController(features: features, hub: hub, openSettings: {})
        let preferences = SettingsWindowController(features: features, hub: hub)
        for (name, appearance) in appearances {
            let window = try #require(dashboard.window)
            window.appearance = NSAppearance(named: appearance)
            let content = try #require(window.contentView)
            content.layoutSubtreeIfNeeded()
            let commands = try #require(descendants(content).first { $0.accessibilityIdentifier() == "dashboard-commands" } as? NSTableView)
            let commandScroll = try #require(commands.enclosingScrollView)
            #expect(commands.numberOfRows == features.flatMap(\.commands).count)
            #expect(content.frame.width <= 460 && content.frame.height <= CGFloat(features.flatMap(\.commands).count) * commands.rowHeight + 80)
            #expect(!descendants(content).contains { $0 is NSGlassEffectView })
            #expect(content.bounds.contains(content.convert(commandScroll.bounds, from: commandScroll)))
            var shortcutEdges: [CGFloat] = []
            for row in 0..<commands.numberOfRows {
                let cell = try #require(commands.view(atColumn: 0, row: row, makeIfNecessary: true))
                cell.layoutSubtreeIfNeeded()
                let shortcut = try #require(descendants(cell).first { $0.accessibilityIdentifier() == "dashboard-shortcut" })
                let frame = cell.convert(shortcut.bounds, from: shortcut)
                #expect(cell.bounds.contains(frame) && frame.maxX >= cell.bounds.maxX - 12)
                shortcutEdges.append(commands.convert(shortcut.bounds, from: shortcut).maxX)
            }
            #expect(shortcutEdges.allSatisfy { abs($0 - shortcutEdges[0]) < 1 })
            try render(window, named: "toolbox-\(name)")
            let settingsWindow = try #require(preferences.window)
            settingsWindow.appearance = NSAppearance(named: appearance)
            settingsWindow.setContentSize(CGSize(width: 740, height: 510))
            let settingsContent = try #require(settingsWindow.contentView)
            let sidebar = try #require(descendants(settingsContent).first { $0 is NSTableView } as? NSTableView)
            preferences.selectFeature("monitor")
            #expect(sidebar.selectedRow == 5)
            for row in [0, 2, 3, 4, 5] {
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

    @Test func systemMonitorFitsSmallScreensAndKeepsMetricsOutsideGlass() throws {
        _ = NSApplication.shared
        let controller = SystemMonitorViewController()
        controller.loadViewIfNeeded()
        var snapshot = SystemMetricsSnapshot()
        snapshot.cpu = 0.98
        snapshot.coreLoads = Array(repeating: 0.98, count: 32)
        snapshot.memory = SystemMemory(used: 120 * 1_024 * 1_024 * 1_024, total: 128 * 1_024 * 1_024 * 1_024,
                                       compressed: 8 * 1_024 * 1_024 * 1_024, swap: 0, pressure: 2)
        snapshot.gpu = 1
        snapshot.network = SystemIORate(incoming: 100_000_000, outgoing: 100_000_000)
        snapshot.diskIO = snapshot.network
        snapshot.diskSpace = SystemDiskSpace(total: 1_000_000_000_000, available: 500_000_000_000)
        snapshot.battery = SystemBattery(fraction: 1, charging: false, pluggedIn: true)
        snapshot.cpuTemperature = 99
        snapshot.gpuTemperature = 80
        snapshot.fanRPM = [5_000, 5_000]
        snapshot.thermalState = 2
        snapshot.sampledAt = Date()
        for (name, appearance) in appearances {
            for height in [320.0, 440.0] {
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: height),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = controller.view
                window.setContentSize(CGSize(width: 400, height: height))
                controller.render(snapshot, history: (0..<60).map { Double($0) / 60 })
                let content = controller.view
                content.layoutSubtreeIfNeeded()
                let scroll = try #require(descendants(content).compactMap { $0 as? NSScrollView }.first)
                #expect(content.bounds.contains(content.convert(scroll.bounds, from: scroll)))
                #expect(scroll.frame.height > 160)
                let document = try #require(scroll.documentView)
                #expect(abs(document.frame.width - scroll.contentView.bounds.width) < 1)
                #expect(document.frame.height >= 340)
                #expect(!descendants(document).contains { $0 is NSGlassEffectView })
                let fields = descendants(document).compactMap { $0 as? NSTextField }
                #expect(fields.allSatisfy {
                    let rect = document.convert($0.bounds, from: $0)
                    return rect.minX >= -1 && rect.maxX <= document.bounds.maxX + 1
                })
                let buttons = descendants(content).compactMap { $0 as? NSButton }
                #expect(buttons.count == 4)
                #expect(buttons.allSatisfy { content.bounds.contains(content.convert($0.bounds, from: $0)) })
                #expect(buttons.allSatisfy { $0.frame.width >= 28 && $0.frame.height >= 28 })
                let cpu = try #require(descendants(document).first { $0.accessibilityIdentifier() == "monitor-cpu" })
                let memory = try #require(descendants(document).first { $0.accessibilityIdentifier() == "monitor-memory" })
                #expect(cpu.frame.width >= 170 && memory.frame.width >= 170)
                #expect(abs(cpu.frame.width - memory.frame.width) < 1)
                try render(window, named: "monitor-\(Int(height))-\(name)")
                // Unsupported hardware keeps the same row layout and exposes an explanation.
                var missing = SystemMetricsSnapshot()
                missing.notes["temperature"] = "此设备未提供传感器"
                controller.render(missing, history: [nil])
                content.layoutSubtreeIfNeeded()
                #expect(descendants(document).first { $0.accessibilityIdentifier() == "monitor-temperature" }?.toolTip?.contains("此设备未提供传感器") == true)
            }
        }
    }

    @Test func monitorContentDoesNotPaintOverTheNativePopoverBackdrop() throws {
        _ = NSApplication.shared
        let controller = SystemMonitorViewController()
        controller.loadViewIfNeeded()
        // Render the root's background pass onto a synthetic backdrop. Native material
        // is drawn below this pass; a full-window fill would erase these colors.
        for (_, appearance) in appearances {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 440,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            var backdrop: NSColor?
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.6, alpha: 1).setFill()
                CGRect(x: 0, y: 0, width: 400, height: 440).fill()
                backdrop = bitmap.colorAt(x: 4, y: 220)?.usingColorSpace(.deviceRGB)
                controller.view.draw(controller.view.bounds)
            }
            NSGraphicsContext.restoreGraphicsState()
            let color = try #require(bitmap.colorAt(x: 4, y: 220)?.usingColorSpace(.deviceRGB))
            let original = try #require(backdrop)
            #expect(abs(color.redComponent - original.redComponent) < 0.01)
            #expect(abs(color.greenComponent - original.greenComponent) < 0.01)
            #expect(abs(color.blueComponent - original.blueComponent) < 0.01)
        }
    }

    @Test func clipboardListRemainsCompactWithGlassOnlyInControls() async throws {
        _ = NSApplication.shared
        let suite = "app.suse.layout.\(UUID().uuidString)"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        let pasteboard = NSPasteboard.withUniqueName()
        defer {
            settings.defaults.removePersistentDomain(forName: suite)
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appending(path: suite))
        }
        let store = ClipboardStore(settings: settings, pasteboard: pasteboard,
                                   persistenceURL: FileManager.default.temporaryDirectory.appending(path: "\(suite)/history.sqlite"),
            source: { ClipboardSource(name: "Fixture", bundleIdentifier: "com.example.fixture") })
        for text in ["随手记录一个想法", "一个快捷键，自动选择屏幕和窗口。", "原生界面，紧凑布局。",
                     "保留内容的清晰度，让操作控件浮在上方。", "可以用方向键选择历史内容。", "superuse · 截图与剪贴板"] {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            store.checkForChanges()
        }
        let pins = PinsModule(pasteboard: pasteboard, showsWindows: false)
        let image = screenshotFixture(size: CGSize(width: 240, height: 160))
        let imageData = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        pasteboard.clearContents()
        pasteboard.setData(imageData, forType: .png)
        store.checkForChanges()
        for record in try await store.page().records.prefix(2) { store.setPinned(record, pinned: true) }
        let controller = ClipboardPanelController(store: store, pins: pins)
        await controller.waitForReload()
        let window = try #require(controller.window)
        for (name, appearance) in appearances {
            window.appearance = NSAppearance(named: appearance)
            let content = try #require(window.contentView)
            content.layoutSubtreeIfNeeded()
            let table = try #require(descendants(content).first { $0 is NSTableView } as? NSTableView)
            #expect(table.numberOfRows == 7)
            #expect(table.rowHeight == 58)
            let scroll = try #require(table.enclosingScrollView)
            #expect(scroll.frame.height >= 290)
            #expect(content.bounds.contains(content.convert(scroll.bounds, from: scroll)))
            #expect(window.toolbar?.items.contains { $0 is NSSearchToolbarItem } == true)
            try render(window, named: "clipboard-\(name)")
        }
    }

    @Test func pinWindowsUseNativeToolbarsAndKeepContentOutsideGlass() throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let store = PinStore()
        try store.insert(PinRequest(content: .text(String(repeating: "参考内容 · 可以选中复制\n", count: 40)), source: .screenshot))
        let image = screenshotFixture(size: CGSize(width: 1200, height: 800))
        try store.insert(PinRequest(content: .image(image, pointSize: CGSize(width: 600, height: 400)), source: .screenshot))
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
        for (index, item) in store.items.enumerated() {
            let controller = PinWindowController(item: item, visibleFrame: screen, anchor: CGPoint(x: 100, y: 700), pasteboard: pasteboard)
            let window = try #require(controller.window)
            for (name, appearance) in appearances {
                window.appearance = NSAppearance(named: appearance)
                for size in [CGSize(width: 280, height: 168), CGSize(width: 560, height: 420)] {
                    window.setContentSize(size)
                    let content = try #require(window.contentView)
                    content.layoutSubtreeIfNeeded()
                    let scroll = try #require(descendants(content).first { $0 is NSScrollView } as? NSScrollView)
                    let toolbar = try #require(window.toolbar)
                    #expect(window.styleMask.contains(.titled))
                    #expect(window.titleVisibility == .hidden)
                    #expect(window.standardWindowButton(.closeButton) != nil)
                    #expect(!descendants(content).contains { $0 is NSGlassEffectView })
                    #expect(toolbar.items.contains { $0.itemIdentifier.rawValue == "pin.copy" })
                    #expect(toolbar.items.contains { $0 is NSMenuToolbarItem })
                    if let zoom = toolbar.items.first(where: { $0 is NSToolbarItemGroup }) {
                        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
                        #expect(zoom.isHidden == (window.frame.width < 480))
                    }
                    #expect(scroll.frame.height >= 120)
                    if let image = descendants(content).compactMap({ $0 as? NSImageView }).first {
                        let canvas = try #require(scroll.documentView)
                        #expect(abs(image.frame.midX - canvas.bounds.midX) < 1)
                        #expect(abs(image.frame.midY - canvas.bounds.midY) < 1)
                        #expect(abs(image.frame.width / image.frame.height - 1.5) < 0.01)
                        #expect(image.frame.width <= scroll.contentSize.width - 31)
                        #expect(abs(scroll.contentView.convert(image.bounds, from: image).midX - scroll.contentView.bounds.midX) < 1)
                    }
                    if let text = controller.textView { #expect(abs(text.frame.width - scroll.contentSize.width) < 1) }
                    try render(window, named: "pin-\(index)-\(Int(size.width))-\(name)", includingFrame: true)
                }
            }
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
            for control in [container, status] {
                #expect(control.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ==
                        window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]))
            }
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

    private func render(_ window: NSWindow, named name: String, includingFrame: Bool = false) throws {
        guard let directory = ProcessInfo.processInfo.environment["SUSE_UI_PREVIEW_DIRECTORY"] else { return }
        let view = try #require(includingFrame ? window.contentView?.superview : window.contentView)
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
