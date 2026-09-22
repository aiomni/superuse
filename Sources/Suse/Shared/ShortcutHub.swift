import AppKit
import Carbon
import SuseCore

/// Carbon hot keys work without Accessibility access and respect system-level conflicts.
@MainActor
final class ShortcutHub {
    private let settings: SettingsStore
    private var registrations: [String: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var numericIDs: [UInt32: String] = [:]
    private var suspended = false
    private(set) var commands: [AppCommand] = []
    private(set) var errors: [String: String] = [:]
    var onChange: (() -> Void)?

    init(settings: SettingsStore) { self.settings = settings }

    func install(_ commands: [AppCommand]) {
        self.commands = commands
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installResult = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard result == noErr else { return result }
            MainActor.assumeIsolated {
                Unmanaged<ShortcutHub>.fromOpaque(context).takeUnretainedValue().invoke(key.id)
            }
            return noErr
        }, 1, &event, context, &eventHandler)
        guard installResult == noErr else {
            for command in commands { errors[command.id] = "快捷键事件监听失败（\(installResult)），请重新启动 \(AppIdentity.name)。" }
            return
        }
        for (index, command) in commands.enumerated() {
            numericIDs[UInt32(index + 1)] = command.id
            if let shortcut = shortcut(for: command) {
                do { try register(shortcut, command: command) }
                catch { errors[command.id] = error.localizedDescription }
            }
        }
    }

    func stop() {
        registrations.values.forEach { UnregisterEventHotKey($0) }
        registrations.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    func suspendForRecording() {
        suspended = true
        registrations.values.forEach { UnregisterEventHotKey($0) }
        registrations.removeAll()
    }

    func resumeAfterRecording() {
        guard suspended else { return }
        suspended = false
        guard eventHandler != nil else { return }
        errors.removeAll()
        for command in commands {
            guard let shortcut = shortcut(for: command) else { continue }
            do { try register(shortcut, command: command) }
            catch { errors[command.id] = error.localizedDescription }
        }
        onChange?()
    }

    func shortcut(for command: AppCommand) -> Shortcut? {
        settings.isShortcutDisabled(command.id) ? nil : settings.shortcut(for: command.id) ?? command.defaultShortcut
    }

    func update(_ shortcut: Shortcut?, for command: AppCommand) throws {
        if let shortcut {
            guard shortcut.isValidGlobalShortcut else { throw AppError("请至少包含 Control、Option 或 Command 修饰键。") }
            if let other = commands.first(where: { $0.id != command.id && self.shortcut(for: $0) == shortcut }) {
                throw AppError("这个快捷键已用于「\(other.title)」。")
            }
        }
        let previous = self.shortcut(for: command)
        if let old = registrations.removeValue(forKey: command.id) { UnregisterEventHotKey(old) }
        do {
            if let shortcut { try register(shortcut, command: command) }
            if suspended, let probe = registrations.removeValue(forKey: command.id) { UnregisterEventHotKey(probe) }
            settings.save(shortcut: shortcut, for: command.id)
            settings.setShortcutDisabled(shortcut == nil, for: command.id)
            errors.removeValue(forKey: command.id)
            onChange?()
        } catch {
            if let previous, !suspended { try? register(previous, command: command) }
            throw error
        }
    }

    private func register(_ shortcut: Shortcut, command: AppCommand) throws {
        guard let id = numericIDs.first(where: { $0.value == command.id })?.key else { return }
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers.carbonValue,
                                        EventHotKeyID(signature: 0x53555345, id: id),
                                        GetApplicationEventTarget(), 0, &reference)
        guard result == noErr, let reference else {
            throw AppError("\(shortcut.displayValue) 无法注册，可能已被其他应用占用（\(result)）。")
        }
        registrations[command.id] = reference
    }

    private func invoke(_ id: UInt32) {
        guard let commandID = numericIDs[id] else { return }
        commands.first(where: { $0.id == commandID })?.perform()
    }
}

extension ShortcutModifiers {
    var carbonValue: UInt32 {
        var value: UInt32 = 0
        if contains(.control) { value |= UInt32(controlKey) }
        if contains(.option) { value |= UInt32(optionKey) }
        if contains(.shift) { value |= UInt32(shiftKey) }
        if contains(.command) { value |= UInt32(cmdKey) }
        return value
    }

    init(eventFlags: NSEvent.ModifierFlags) {
        self = []
        if eventFlags.contains(.control) { insert(.control) }
        if eventFlags.contains(.option) { insert(.option) }
        if eventFlags.contains(.shift) { insert(.shift) }
        if eventFlags.contains(.command) { insert(.command) }
    }
}

@MainActor
final class ShortcutRecorder: NSButton {
    private let command: AppCommand
    private let hub: ShortcutHub
    private var recording = false
    override var acceptsFirstResponder: Bool { true }

    init(command: AppCommand, hub: ShortcutHub) {
        self.command = command
        self.hub = hub
        super.init(frame: .zero)
        bezelStyle = .rounded
        font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        target = self
        action = #selector(beginRecording)
        toolTip = "点击后按下快捷键；Delete 停用；Escape 取消"
        setAccessibilityLabel("\(command.title) 快捷键")
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @objc private func beginRecording() {
        window?.makeFirstResponder(self)
        hub.suspendForRecording()
        recording = true
        title = "按下快捷键…"
    }

    override func resignFirstResponder() -> Bool {
        finishRecording()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finishRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { finishRecording(); return }
        let shortcut: Shortcut? = event.keyCode == 51 ? nil :
            Shortcut(keyCode: UInt32(event.keyCode), modifiers: .init(eventFlags: event.modifierFlags))
        do { try hub.update(shortcut, for: command) }
        catch { finishRecording(); UI.error(error, in: window) }
        finishRecording()
    }

    private func finishRecording() {
        guard recording else { return }
        recording = false
        hub.resumeAfterRecording()
        refresh()
    }

    private func refresh() { title = hub.shortcut(for: command)?.displayValue ?? "未设置" }
}
