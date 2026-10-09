import Testing
@testable import SuseCore

@Test func automaticScrollWaitsForStabilityAndStopsOnFailedOverlap() {
    var progress = AutomaticScrollProgress()
    #expect(progress.action(after: .settling) == .wait)
    #expect(progress.action(after: .unchanged) == .scroll)
    progress.didScroll()
    #expect(progress.action(after: .settling) == .wait)
    #expect(progress.action(after: .appended(height: 400, frames: 2)) == .scroll)
    #expect(progress.action(after: .rejected("不能匹配")) == .pause("不能匹配"))
    #expect(progress.action(after: .limitReached) == .wait)
}

@Test func automaticScrollStopsAfterThreeStationaryStepsButResetsOnProgress() {
    var progress = AutomaticScrollProgress()
    for _ in 0..<2 {
        progress.didScroll()
        #expect(progress.action(after: .unchanged) == .scroll)
    }
    #expect(progress.action(after: .appended(height: 400, frames: 2)) == .scroll)
    for _ in 0..<2 {
        progress.didScroll()
        #expect(progress.action(after: .unchanged) == .scroll)
    }
    progress.didScroll()
    guard case .pause = progress.action(after: .unchanged) else { Issue.record("Stationary content must stop automation"); return }
}

@Test func automaticScrollDoesNotWaitForeverForAnimationToSettle() {
    var progress = AutomaticScrollProgress()
    for _ in 0..<11 { #expect(progress.action(after: .settling) == .wait) }
    #expect(progress.action(after: .appended(height: 400, frames: 2)) == .scroll)
    for _ in 0..<11 { #expect(progress.action(after: .settling) == .wait) }
    guard case .pause = progress.action(after: .settling) else { Issue.record("Animated content must pause automation"); return }
}
