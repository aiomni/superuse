import AppKit
import ScreenCaptureKit
import SuseCore

@MainActor
struct ScreenSnapshot {
    let display: SCDisplay
    let appKitFrame: CGRect
    let image: CGImage

    func crop(_ quartzRect: CGRect) throws -> CGImage {
        let rect = ScreenGeometry.pixelCrop(selection: quartzRect, displayFrame: display.frame,
                                             pixelSize: CGSize(width: image.width, height: image.height))
        guard !rect.isNull, let cropped = image.cropping(to: rect) else { throw AppError("无法裁剪选定区域。") }
        return cropped
    }
}

@MainActor
final class ScreenCaptureService {
    func content() async throws -> SCShareableContent {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw AppError("请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许 \(AppIdentity.name)，然后重试截图。")
        }
        return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    }

    func snapshot(display: SCDisplay, content: SCShareableContent) async throws -> ScreenSnapshot {
        let filter = displayFilter(display, content: content)
        let config = configuration()
        config.width = Int(display.frame.width * CGFloat(filter.pointPixelScale))
        config.height = Int(display.frame.height * CGFloat(filter.pointPixelScale))
        let result = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config)
        guard let image = result.sdrImage else { throw AppError("系统未返回截图，请重试。") }
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let frame = ScreenGeometry.quartzRect(fromAppKit: display.frame, mainDisplayHeight: mainHeight)
        return ScreenSnapshot(display: display, appKitFrame: frame, image: image)
    }

    func capture(region: CGRect, display: SCDisplay, content: SCShareableContent) async throws -> CGImage {
        let filter = displayFilter(display, content: content)
        let config = configuration()
        config.sourceRect = CGRect(x: region.minX - display.frame.minX, y: region.minY - display.frame.minY,
                                   width: region.width, height: region.height)
        config.width = Int(region.width * CGFloat(filter.pointPixelScale))
        config.height = Int(region.height * CGFloat(filter.pointPixelScale))
        let result = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config)
        guard let image = result.sdrImage else { throw AppError("选定区域已不可用。") }
        return image
    }

    func orderedWindows(in content: SCShareableContent) -> [SCWindow] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows = content.windows.filter {
            $0.windowLayer == 0 && $0.frame.width > 40 && $0.frame.height > 40 &&
            $0.owningApplication?.processID != ownPID
        }
        let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let ids = info.compactMap { $0[kCGWindowNumber as String] as? UInt32 }
        let rank = Dictionary(ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return windows.sorted { (rank[$0.windowID] ?? .max) < (rank[$1.windowID] ?? .max) }
    }

    private func displayFilter(_ display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        return SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
    }

    private func configuration() -> SCScreenshotConfiguration {
        let config = SCScreenshotConfiguration()
        config.showsCursor = false
        config.dynamicRange = .sdr
        return config
    }
}
