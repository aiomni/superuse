import AppKit
import Testing
import SuseCore
@testable import Suse

@Suite(.serialized)
@MainActor
struct ScrollCaptureEngineTests {
    @Test func automaticCaptureWaitsForStableFramesAndClickIncludesLastViewport() async throws {
        let fixture = Fixture()
        let engine = fixture.engine()
        var completed = false
        let run = Task { let result = await engine.run(initialImage: fixture.image()); completed = true; return result }
        try await wait { fixture.posts == 2 }
        #expect(fixture.captureCountsAtPost[0] >= 2)
        #expect(fixture.captureCountsAtPost[1] - fixture.captureCountsAtPost[0] >= 2)
        engine.stopForClick()
        for _ in 0..<20 { await Task.yield() }
        #expect(!completed && fixture.posts == 2)
        engine.finish()
        engine.finish()
        let image = try #require(await run.value)
        #expect(image.width == 128 && image.height == 480)
        #expect(fixture.posts == 2)
        #expect(pixels(image) == pixels(fixture.source.cropping(to: CGRect(x: 0, y: 0, width: 128, height: 480))!))
    }

    @Test func cancellationDuringCaptureDoesNotPostOrResumeTwice() async throws {
        let fixture = Fixture()
        var pending: CheckedContinuation<CGImage, Never>?
        let engine = fixture.engine(capture: { await withCheckedContinuation { pending = $0 } })
        let run = Task { await engine.run(initialImage: fixture.image()) }
        try await wait { pending != nil }
        engine.cancel()
        engine.cancel()
        engine.finish()
        #expect(await run.value == nil)
        pending?.resume(returning: fixture.image())
        pending = nil
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.posts == 0)
    }

    @Test func pausingAndResumingWaitsForCancelledCaptureBeforeStartingAnother() async throws {
        let fixture = Fixture()
        var pending: CheckedContinuation<CGImage, Never>?
        var first = true
        let engine = fixture.engine(capture: {
            if first {
                first = false
                return await withCheckedContinuation { pending = $0 }
            }
            return fixture.image()
        })
        let run = Task { await engine.run(initialImage: fixture.image()) }
        try await wait { pending != nil }
        engine.togglePause()
        engine.togglePause()
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.refreshes == 1 && fixture.posts == 0)
        pending?.resume(returning: fixture.image())
        pending = nil
        try await wait { fixture.refreshes == 2 }
        try await wait { fixture.posts >= 1 }
        engine.cancel()
        #expect(await run.value == nil)
    }

    @Test func permissionDenialKeepsManualCaptureAndSwitchingModesStopsInput() async throws {
        let fixture = Fixture()
        fixture.access = false
        let engine = fixture.engine()
        let run = Task { await engine.run(initialImage: fixture.image()) }
        try await wait { fixture.captures >= 2 }
        #expect(!engine.automatic && fixture.posts == 0 && fixture.requests == 1)
        #expect(fixture.messages.first?.contains("辅助功能权限") == true)
        #expect(fixture.preparations == 0)
        engine.toggleAutomatic()
        #expect(fixture.requests == 2 && fixture.preparations == 0)
        #expect(fixture.messages.last?.contains("辅助功能权限") == true)
        fixture.offset = 80
        try await wait { fixture.messages.contains { $0.contains("已拼接 2 帧") } }
        fixture.access = true
        engine.toggleAutomatic()
        try await wait { fixture.posts >= 1 }
        #expect(fixture.requests == 2 && fixture.preparations == 1)
        engine.toggleAutomatic()
        let posts = fixture.posts
        let captures = fixture.captures
        try await wait { fixture.captures >= captures + 3 }
        #expect(!engine.automatic && fixture.posts == posts)
        engine.cancel()
        #expect(await run.value == nil)
    }

    @Test(arguments: [AutomaticScrollInput.EnableError.missingTarget, .clickMonitorUnavailable])
    func authorizedStartupFailuresExplainTheCauseAndKeepManualCapture(failure: AutomaticScrollInput.EnableError) async throws {
        let fixture = Fixture()
        fixture.monitorReady = failure != .clickMonitorUnavailable
        let engine = fixture.engine(windowID: failure == .missingTarget ? nil : 84)
        let run = Task { await engine.run(initialImage: fixture.image()) }
        try await wait { fixture.captures >= 2 }
        let message = try #require(fixture.messages.first)
        #expect(message.contains(failure == .missingTarget ? "未找到目标窗口" : "无法监听选区点击"))
        #expect(!message.contains("辅助功能"))
        #expect(!engine.automatic && fixture.posts == 0 && fixture.requests == 0)
        engine.toggleAutomatic()
        #expect(fixture.messages.last == message)
        #expect(!engine.automatic && fixture.requests == 0)
        fixture.offset = 80
        try await wait { fixture.messages.contains { $0.contains("已拼接 2 帧") } }
        if failure == .clickMonitorUnavailable {
            fixture.monitorReady = true
            engine.toggleAutomatic()
            try await wait { fixture.posts >= 1 }
            #expect(engine.automatic && fixture.requests == 0)
        }
        engine.cancel()
        #expect(await run.value == nil)
    }

    @Test(arguments: [false, true])
    func mismatchAndCapacityLimitStopBeforeSendingAnotherScroll(limit: Bool) async throws {
        let fixture = Fixture()
        let unrelated = Fixture(seed: 998).source
        let engine = fixture.engine(stitcher: ScrollStitcher(pixelLimit: limit ? 128 * 350 : 48_000_000), capture: {
            if !limit && fixture.posts > 0 { return unrelated.cropping(to: CGRect(x: 0, y: 0, width: 128, height: 320))! }
            return fixture.image()
        })
        let run = Task { await engine.run(initialImage: fixture.image()) }
        try await wait { fixture.states.contains(limit ? .limitReached : .retry) }
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.posts == 1)
        if limit {
            engine.togglePause()
            engine.toggleAutomatic()
            for _ in 0..<20 { await Task.yield() }
            #expect(fixture.posts == 1)
        }
        engine.finish()
        let image = try #require(await run.value)
        #expect(image.height == 320)
    }

    @Test func stationaryContentPausesAndFocusLossDoesNotCaptureAnotherApplication() async throws {
        let fixture = Fixture()
        fixture.movesOnScroll = false
        let engine = fixture.engine()
        let run = Task { await engine.run(initialImage: fixture.image()) }
        try await wait { fixture.states.contains(.retry) }
        #expect(fixture.posts == 3)
        fixture.frontmost = 43
        let captures = fixture.captures
        engine.togglePause()
        try await wait { fixture.messages.contains { $0.contains("目标应用已切换") } }
        #expect(fixture.captures == captures && fixture.posts == 3)
        engine.cancel()
        #expect(await run.value == nil)
    }

    @Test func cancellingRunTaskAndEarlyFinishDoNotLeaveSamplingAlive() async throws {
        let fixture = Fixture()
        let engine = fixture.engine()
        let run = Task { await engine.run(initialImage: fixture.image()) }
        try await wait { fixture.captures >= 1 }
        run.cancel()
        #expect(await run.value == nil)
        let posts = fixture.posts
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.posts == posts)

        let early = fixture.engine()
        early.finish()
        let image = try #require(await early.run(initialImage: fixture.image()))
        #expect(image.height == 320)
        let cancelled = fixture.engine()
        cancelled.cancel()
        #expect(await cancelled.run(initialImage: fixture.image()) == nil)
    }

    @Test func clickingAfterAutomaticCapturePausesStillFinishesWithoutMoreInput() async throws {
        let fixture = Fixture()
        fixture.movesOnScroll = false
        let engine = fixture.engine()
        let run = Task { await engine.run(initialImage: fixture.image()) }
        try await wait { fixture.states.contains(.retry) }
        let captures = fixture.captures
        engine.stopForClick()
        engine.finish()
        let image = try #require(await run.value)
        #expect(image.height == 320)
        #expect(fixture.captures == captures && fixture.posts == 3)
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<10_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Capture did not reach the expected state")
        throw AppError("Test timeout")
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

    @MainActor
    private final class Fixture {
        let source: CGImage
        var offset = 0, posts = 0, captures = 0, refreshes = 0, requests = 0, preparations = 0
        var access = true
        var monitorReady = true
        var frontmost: pid_t? = 42
        var movesOnScroll = true
        var captureCountsAtPost: [Int] = []
        var states: [ScrollCaptureState] = []
        var messages: [String] = []

        init(seed: UInt32 = 42) {
            var bytes = [UInt8](repeating: 255, count: 128 * 1200 * 4)
            for y in 0..<1200 {
                for x in 0..<128 {
                    var hash = UInt32(y) &* 374_761_393 &+ UInt32(x) &* 668_265_263 &+ seed
                    hash = (hash ^ (hash >> 13)) &* 1_274_126_177
                    let value = UInt8((hash ^ (hash >> 16)) & 255)
                    for component in 0..<3 { bytes[(y * 128 + x) * 4 + component] = value }
                }
            }
            source = CGImage(width: 128, height: 1200, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 512,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                             provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                             shouldInterpolate: false, intent: .defaultIntent)!
        }

        func image() -> CGImage {
            source.cropping(to: CGRect(x: 0, y: min(offset, 880), width: 128, height: 320))!
        }

        func engine(stitcher: ScrollStitcher = ScrollStitcher(), windowID: CGWindowID? = 84,
                    capture: (() async -> CGImage)? = nil) -> ScrollCaptureEngine {
            let input = AutomaticScrollInput(region: CGRect(x: 0, y: 0, width: 128, height: 320), hasAccess: { self.access },
                                             requestAccess: { self.requests += 1; return false }, frontmostPID: { self.frontmost },
                                             modifiers: { [] }, targetIsVisible: { _, _, _ in true }, prepare: {
                self.preparations += 1
                return self.monitorReady
            }, post: { _ in
                self.posts += 1
                self.captureCountsAtPost.append(self.captures)
                if self.movesOnScroll { self.offset += 80 }
            })
            input.targetPID = 42
            input.targetWindowID = windowID
            let engine = ScrollCaptureEngine(input: input, stitcher: stitcher, captureFrame: {
                self.captures += 1
                return await capture?() ?? self.image()
            }, refreshContent: { self.refreshes += 1 }, sleep: { _ in
                try await Task.sleep(for: .milliseconds(2))
            })
            engine.onUpdate = { self.states.append($0); self.messages.append($1) }
            return engine
        }
    }
}
