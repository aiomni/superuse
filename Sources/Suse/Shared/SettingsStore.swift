import Foundation
import SuseCore

@MainActor
final class SettingsStore {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "clipboard.enabled": true,
            "clipboard.limit": 100,
            "clipboard.persist": false,
            "clipboard.ignoreSensitive": true,
            "screenshot.copyAfterCapture": true,
        ])
    }

    func shortcut(for id: String) -> Shortcut? {
        guard let data = defaults.data(forKey: "shortcut.\(id)") else { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    func save(shortcut: Shortcut?, for id: String) {
        if let shortcut { defaults.set(try? JSONEncoder().encode(shortcut), forKey: "shortcut.\(id)") }
        else { defaults.removeObject(forKey: "shortcut.\(id)") }
    }

    func isShortcutDisabled(_ id: String) -> Bool { defaults.bool(forKey: "shortcut.disabled.\(id)") }
    func setShortcutDisabled(_ disabled: Bool, for id: String) {
        defaults.set(disabled, forKey: "shortcut.disabled.\(id)")
    }
}
