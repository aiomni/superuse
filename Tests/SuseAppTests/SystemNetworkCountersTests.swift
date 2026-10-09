import Foundation
import Darwin
import Testing
import SuseCore
@testable import Suse

struct SystemNetworkCountersTests {
    @Test func mixedRoutingMessagesPreserve64BitTrafficAndIdleRates() throws {
        let large = UInt64(UInt32.max) + 100
        let first = interface(index: 1, incoming: large, outgoing: large) + addressMessage() +
            interface(index: 2, incoming: 50_000, outgoing: 50_000)
        let second = addressMessage() + interface(index: 1, incoming: large + 1_000, outgoing: large + 2_000) +
            addressMessage() + interface(index: 2, incoming: 50_000, outgoing: 50_000)
        let names: [UInt32: String] = [1: "en0", 2: "en1"]
        let baseline = try #require(SystemMetricsSampler.parseNetworkCounters(first, interfaceName: { names[$0] }))
        let updated = try #require(SystemMetricsSampler.parseNetworkCounters(second, interfaceName: { names[$0] }))
        #expect(baseline["en0"]?.incoming == large)
        #expect(updated.count == 2)
        var rates = SystemIOCounters()
        #expect(rates.sample(baseline, elapsed: 1) == nil)
        #expect(rates.sample(updated, elapsed: 1) == SystemIORate(incoming: 1_000, outgoing: 2_000))
        #expect(rates.sample(updated, elapsed: 1) == SystemIORate(incoming: 0, outgoing: 0))
    }

    @Test func virtualInactiveAndLoopbackInterfacesAreNotCountedTwice() throws {
        let data = interface(index: 1, incoming: 100, outgoing: 200) +
            interface(index: 2, incoming: 1_000, outgoing: 2_000) +
            interface(index: 3, incoming: 3_000, outgoing: 4_000, flags: IFF_UP) +
            interface(index: 4, incoming: 3_000, outgoing: 4_000, flags: IFF_UP | IFF_RUNNING | IFF_LOOPBACK) +
            interface(index: 5, incoming: 3_000, outgoing: 4_000)
        let names: [UInt32: String] = [1: "en0", 2: "utun0", 3: "en1", 4: "lo0"]
        let parsed = try #require(SystemMetricsSampler.parseNetworkCounters(data, interfaceName: { names[$0] }))
        #expect(parsed == ["en0": .init(incoming: 100, outgoing: 200)])
        #expect(SystemMetricsSampler.parseNetworkCounters(addressMessage(), interfaceName: { _ in nil }) == [:])
    }

    @Test func malformedMessagesFailWithoutReadingBeyondTheirBounds() {
        let valid = interface(index: 1, incoming: 10, outgoing: 20)
        let malformed: [Data] = [
            Data([0, 0, UInt8(RTM_VERSION)]),
            Data([0, 0, UInt8(RTM_VERSION), UInt8(RTM_NEWADDR)]),
            Data([100, 0, UInt8(RTM_VERSION), UInt8(RTM_NEWADDR)]),
            Data([4, 0, UInt8(RTM_VERSION), UInt8(RTM_IFINFO2)]),
            Data([4, 0, 0, UInt8(RTM_IFINFO2)]),
            valid.dropLast(),
            valid + Data([1]),
        ]
        for data in malformed {
            #expect(SystemMetricsSampler.parseNetworkCounters(data, interfaceName: { _ in "en0" }) == nil)
        }
        #expect(SystemMetricsSampler.parseNetworkCounters(Data(), interfaceName: { _ in nil }) == [:])
    }

    private func interface(index: UInt16, incoming: UInt64, outgoing: UInt64,
                           flags: Int32 = IFF_UP | IFF_RUNNING) -> Data {
        var info = if_msghdr2()
        info.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
        info.ifm_version = UInt8(RTM_VERSION)
        info.ifm_type = UInt8(RTM_IFINFO2)
        info.ifm_flags = flags
        info.ifm_index = index
        info.ifm_data.ifi_ibytes = incoming
        info.ifm_data.ifi_obytes = outgoing
        return withUnsafeBytes(of: &info) { Data($0) }
    }

    private func addressMessage() -> Data {
        var info = ifa_msghdr()
        info.ifam_msglen = UInt16(MemoryLayout<ifa_msghdr>.size)
        info.ifam_version = UInt8(RTM_VERSION)
        info.ifam_type = UInt8(RTM_NEWADDR)
        return withUnsafeBytes(of: &info) { Data($0) }
    }
}
