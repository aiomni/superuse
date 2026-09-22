import AppKit
import SuseCore

/// The shell only knows this contract. Feature implementations never import one another.
@MainActor
protocol FeatureModule: AnyObject {
    var id: String { get }
    var title: String { get }
    var symbol: String { get }
    var summary: String { get }
    var commands: [AppCommand] { get }
    func start()
    func stop()
    func makeSettingsView() -> NSView
}

@MainActor
struct AppCommand {
    let id: String
    let title: String
    let group: String
    let symbol: String
    let defaultShortcut: Shortcut
    let perform: () -> Void
}
