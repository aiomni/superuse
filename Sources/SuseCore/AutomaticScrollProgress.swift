import Foundation

/// Advance only after accepting a stable viewport. Failed matches must never trigger another scroll.
public struct AutomaticScrollProgress: Sendable {
    public enum Action: Equatable, Sendable { case wait, scroll, pause(String) }
    private var awaitingMovement = false
    private var stationarySteps = 0
    private var unsettledSamples = 0

    public init() { }

    public mutating func didScroll() { awaitingMovement = true }

    public mutating func action(after result: StitchResult) -> Action {
        switch result {
        case .settling:
            unsettledSamples += 1
            return unsettledSamples >= 12 ? .pause("画面持续变化，自动滚动已暂停。请等待画面稳定后继续。") : .wait
        case .appended:
            unsettledSamples = 0
            stationarySteps = 0
            awaitingMovement = false
            return .scroll
        case .unchanged:
            unsettledSamples = 0
            if awaitingMovement { stationarySteps += 1 }
            awaitingMovement = false
            return stationarySteps >= 3 ? .pause("画面不再变化，可能已到末尾。请完成截图，或切换为手动滚动。") : .scroll
        case .rejected(let reason): return .pause(reason)
        case .limitReached: return .wait
        }
    }
}
