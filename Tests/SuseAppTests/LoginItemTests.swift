import AppKit
import Carbon
import ServiceManagement
import Testing
@testable import Suse

@Suite(.serialized)
@MainActor
struct LoginItemTests {
    @Test func openingSettingsDoesNotRegisterAndTheSwitchControlsRegistration() throws {
        _ = NSApplication.shared
        let service = LoginItemStub()
        let view = LoginItemSettingsView(service: service)
        let toggle = try toggle(in: view)
        #expect(service.registrations == 0)
        #expect(toggle.state == .off)
        toggle.performClick(nil)
        #expect(service.registrations == 1)
        #expect(service.status == .enabled)
        #expect(toggle.state == .on)
        toggle.performClick(nil)
        #expect(service.unregistrations == 1)
        #expect(service.status == .notRegistered)
        #expect(toggle.state == .off)
    }

    @Test func failedUpdatesRestoreTheActualSystemState() throws {
        _ = NSApplication.shared
        for initialStatus in [SMAppService.Status.notRegistered, .enabled] {
            let service = LoginItemStub()
            service.status = initialStatus
            service.error = AppError("测试签名错误")
            let view = LoginItemSettingsView(service: service)
            let toggle = try toggle(in: view)
            toggle.performClick(nil)
            #expect(service.status == initialStatus)
            #expect(toggle.state == (initialStatus == .enabled ? .on : .off))
            #expect(descendants(view).compactMap { $0 as? NSTextField }.contains {
                !$0.isHidden && $0.stringValue.contains("测试签名错误")
            })
        }
    }

    @Test func returningFromSystemSettingsRefreshesApprovalAndEnabledState() throws {
        _ = NSApplication.shared
        let service = LoginItemStub()
        service.status = .enabled
        let view = LoginItemSettingsView(service: service)
        let toggle = try toggle(in: view)
        let settings = try #require(descendants(view).compactMap { $0 as? NSButton }
            .first { $0.title == "打开登录项设置" })
        service.status = .requiresApproval
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        #expect(toggle.state == .off)
        #expect(!settings.isHidden)
        toggle.performClick(nil)
        #expect(service.registrations == 0)
        #expect(toggle.state == .off)
        service.status = .enabled
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        #expect(toggle.state == .on)
        #expect(settings.isHidden)
        service.status = .notFound
        view.refresh()
        #expect(toggle.state == .off)
        #expect(!toggle.isEnabled)
    }

    @Test func registeringAnItemAwaitingApprovalDoesNotClaimItIsEnabled() throws {
        _ = NSApplication.shared
        let service = LoginItemStub()
        service.statusAfterRegistration = .requiresApproval
        let view = LoginItemSettingsView(service: service)
        let toggle = try toggle(in: view)
        toggle.performClick(nil)
        #expect(service.registrations == 1)
        #expect(toggle.state == .off)
        #expect(descendants(view).compactMap { $0 as? NSTextField }.contains {
            !$0.isHidden && $0.stringValue.contains("尚未启用")
        })
    }

    @Test func onlyLoginLaunchesSuppressTheToolbox() {
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: kCoreEventClass, eventID: kAEOpenApplication,
                                                      targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                                      transactionID: AETransactionID(kAnyTransactionID))
        #expect(!AppLaunchContext.isLoginItem(nil))
        #expect(!AppLaunchContext.isLoginItem(event))
        event.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        #expect(AppLaunchContext.isLoginItem(event))
        event.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsServiceItem), forKeyword: keyAEPropData)
        #expect(!AppLaunchContext.isLoginItem(event))
    }

    private func toggle(in view: NSView) throws -> NSSwitch {
        try #require(descendants(view).first { $0 is NSSwitch } as? NSSwitch)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}

@MainActor
private final class LoginItemStub: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var statusAfterRegistration: SMAppService.Status = .enabled
    var error: Error?
    private(set) var registrations = 0
    private(set) var unregistrations = 0

    func register() throws {
        registrations += 1
        if let error { throw error }
        status = statusAfterRegistration
    }

    func unregister() throws {
        unregistrations += 1
        if let error { throw error }
        status = .notRegistered
    }
}
