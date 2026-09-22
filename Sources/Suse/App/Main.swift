import AppKit

@main
enum Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let coordinator = AppCoordinator()
        app.delegate = coordinator
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(coordinator) { app.run() }
    }
}
