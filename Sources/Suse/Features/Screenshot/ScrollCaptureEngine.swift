import CoreGraphics
import SuseCore

enum ScrollCaptureState { case recording, paused, retry, limitReached, finishing }

/// Serializes scroll, settle, and capture work; owns cancellation and the single completion.
@MainActor
final class ScrollCaptureEngine {
    private let stitcher: ScrollStitcher
    private let captureFrame: () async throws -> CGImage
    private let refreshContent: () async throws -> Void
    private let input: AutomaticScrollInput
    private let sleep: (Duration) async throws -> Void
    private var task: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var completion: CheckedContinuation<CGImage?, Never>?
    private var progress = AutomaticScrollProgress()
    private var paused = false
    private var finishing = false
    private var stoppingForClick = false
    private var finishRequested = false
    private(set) var cancelled = false
    private var reachedLimit = false
    private var frameCount = 1
    private(set) var automatic = false
    var onUpdate: ((ScrollCaptureState, String) -> Void)?

    init(input: AutomaticScrollInput, stitcher: ScrollStitcher = ScrollStitcher(),
         captureFrame: @escaping () async throws -> CGImage,
         refreshContent: @escaping () async throws -> Void,
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.input = input
        self.stitcher = stitcher
        self.captureFrame = captureFrame
        self.refreshContent = refreshContent
        self.sleep = sleep
    }

    func run(initialImage: CGImage) async -> CGImage? {
        guard !cancelled, !Task.isCancelled else { return nil }
        let initial = await stitcher.append(initialImage)
        guard !cancelled, !Task.isCancelled else { return nil }
        guard case .appended = initial else {
            onUpdate?(.limitReached, "选区过大，请缩小后重试。")
            return nil
        }
        if finishRequested {
            let image = await stitcher.makeImage()
            return cancelled || Task.isCancelled ? nil : image
        }
        let initialMessage: String
        do {
            try input.enable(prompt: true)
            automatic = true
            initialMessage = "自动向下滚动 · 点击选区完成"
        } catch {
            automatic = false
            initialMessage = error.localizedDescription
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion = continuation
                onUpdate?(.recording, initialMessage)
                startSampling()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private var canSample: Bool { !paused && !finishing && !stoppingForClick && !cancelled }

    private func startSampling() {
        let previousTask = task
        previousTask?.cancel()
        progress = AutomaticScrollProgress()
        task = Task { [weak self] in
            await previousTask?.value
            guard let self, !Task.isCancelled else { return }
            do {
                try await refreshContent()
                try Task.checkCancellation()
                await stitcher.resetStability()
                while !Task.isCancelled && canSample {
                    try await sleep(.milliseconds(400))
                    try Task.checkCancellation()
                    guard canSample else { return }
                    if automatic { try input.validateTarget() }
                    let image = try await captureFrame()
                    try Task.checkCancellation()
                    guard canSample else { return }
                    if automatic { try input.validateTarget() }
                    let result = await stitcher.ingest(image)
                    try Task.checkCancellation()
                    guard canSample else { return }
                    switch result {
                    case .appended(let height, let frames):
                        frameCount = frames
                        onUpdate?(.recording, "已拼接 \(frames) 帧 · 长图高度 \(height) px")
                    case .unchanged, .settling: break
                    case .rejected(let reason):
                        if !automatic { onUpdate?(.recording, reason) }
                    case .limitReached:
                        pause(state: .limitReached, message: "已达到 30,000 px / 48 MP 上限")
                        return
                    }
                    if automatic {
                        switch progress.action(after: result) {
                        case .wait: break
                        case .pause(let reason):
                            pause(state: .retry, message: reason)
                            return
                        case .scroll:
                            await stitcher.resetStability()
                            try Task.checkCancellation()
                            guard canSample else { return }
                            if try input.scrollDown() { progress.didScroll() }
                        }
                    }
                }
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, canSample else { return }
                pause(state: .retry, message: "捕获暂停：\(error.localizedDescription)")
            }
        }
    }

    private func pause(state: ScrollCaptureState, message: String) {
        paused = true
        if state == .limitReached { reachedLimit = true }
        task?.cancel()
        onUpdate?(state, message)
    }

    func togglePause() {
        guard !finishing, !stoppingForClick, !cancelled, !reachedLimit else { return }
        if paused {
            paused = false
            onUpdate?(.recording, "继续捕获 · 已记录 \(frameCount) 帧")
            startSampling()
        } else {
            pause(state: .paused, message: "已暂停 · \(frameCount) 帧")
        }
    }

    func toggleAutomatic() {
        guard !finishing, !stoppingForClick, !cancelled, !reachedLimit else { return }
        if automatic {
            automatic = false
        } else {
            do {
                try input.enable(prompt: true)
            } catch {
                onUpdate?(paused ? .paused : .recording, error.localizedDescription)
                return
            }
            automatic = true
        }
        paused = false
        onUpdate?(.recording, automatic ? "自动向下滚动 · 点击选区完成" : "请手动向下滚动 · 停稳后自动拼接")
        startSampling()
    }

    /// Mouse-down stops input immediately; retain click interception through the matching mouse-up.
    func stopForClick() {
        guard !finishing, !cancelled else { return }
        stoppingForClick = true
        task?.cancel()
        onUpdate?(.finishing, "已停止滚动 · 松开鼠标完成截图")
    }

    func inputUnavailable() {
        guard canSample else { return }
        pause(state: .retry, message: "无法继续控制原窗口，自动滚动已暂停。请返回原窗口重试，或切换为手动滚动。")
    }

    func finish() {
        guard !cancelled else { return }
        guard completion != nil else { finishRequested = true; return }
        guard !finishing else { return }
        finishing = true
        task?.cancel()
        onUpdate?(.finishing, "正在生成长图…")
        let sampling = task
        finishTask = Task { [weak self] in
            await sampling?.value
            guard let self, !cancelled, !Task.isCancelled else { return }
            if !paused {
                // Capture the last stable viewport, including an in-flight scroll stopped by a click.
                for _ in 0..<10 {
                    do {
                        try await sleep(.milliseconds(200))
                        try Task.checkCancellation()
                        if automatic { try input.validateTarget() }
                        let image = try await captureFrame()
                        try Task.checkCancellation()
                        if automatic { try input.validateTarget() }
                        let result = await stitcher.ingest(image)
                        try Task.checkCancellation()
                        if result == .settling { continue }
                    } catch { }
                    break
                }
            }
            guard !cancelled, !Task.isCancelled else { return }
            let image = await stitcher.makeImage()
            guard !cancelled, !Task.isCancelled else { return }
            complete(image)
        }
    }

    private func complete(_ image: CGImage?) {
        let pending = completion
        completion = nil
        pending?.resume(returning: image)
    }

    func cancel() {
        cancelled = true
        task?.cancel()
        finishTask?.cancel()
        complete(nil)
    }
}
