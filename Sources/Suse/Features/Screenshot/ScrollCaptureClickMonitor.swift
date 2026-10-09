import AppKit

/// Consumes only the finishing left-click pair. The outline stays transparent to scroll-wheel routing.
@MainActor
final class ScrollCaptureClickMonitor {
    private let region: CGRect
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pressed = false
    var enabled = false
    var excludesPoint: (CGPoint) -> Bool = { _ in false }
    var targetIsActive: () -> Bool = { true }
    var onStop: (() -> Void)?
    var onFinish: (() -> Void)?
    var onUnavailable: (() -> Void)?

    init(region: CGRect) { self.region = region }

    func start() -> Bool {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            return CGEvent.tapIsEnabled(tap: tap)
        }
        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue) | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<ScrollCaptureClickMonitor>.fromOpaque(context).takeUnretainedValue()
            let location = event.location
            let consumed = MainActor.assumeIsolated {
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    let wasActive = monitor.enabled || monitor.pressed
                    monitor.enabled = false
                    if wasActive { monitor.onUnavailable?() }
                    return false
                }
                return monitor.consume(type: type, location: location)
            }
            return consumed ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }
        self.tap = tap
        runLoopSource = source
        // The callback's main-actor assumption is enforced by this sole run-loop registration.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return CGEvent.tapIsEnabled(tap: tap)
    }

    func consume(type: CGEventType, location: CGPoint) -> Bool {
        if type == .leftMouseDown, pressed { return true }
        if type == .leftMouseUp, pressed {
            pressed = false
            onFinish?()
            return true
        }
        guard type == .leftMouseDown, enabled, region.contains(location), !excludesPoint(location) else { return false }
        guard targetIsActive() else {
            enabled = false
            onUnavailable?()
            return false
        }
        guard !pressed else { return true }
        pressed = true
        onStop?()
        return true
    }

    func stop() {
        enabled = false
        pressed = false
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        runLoopSource = nil
        tap = nil
    }
}
