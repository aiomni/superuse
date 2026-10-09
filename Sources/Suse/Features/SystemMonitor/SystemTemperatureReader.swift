import Foundation
import IOKit

/// Read-only AppleSMC transport adapted from AirStats (MIT); see ThirdPartyNotices.txt.
/// Confined to SystemMetricsSampler. The SMC protocol is undocumented and may be unavailable.
final class SystemTemperatureReader {
    struct Reading {
        var cpu: Double?
        var gpu: Double?
        var fans: [Double] = []
    }

    private struct Sensor {
        var key: UInt32
        var size: UInt32
        var type: UInt32
        var isGPU: Bool
    }

    private var connection: io_connect_t = 0
    private var request: UnsafeMutableRawPointer?
    private var reply: UnsafeMutableRawPointer?
    private var sensors: [Sensor] = []
    private var fans: [Sensor] = []
    private var attempted = false

    deinit { close() }

    func close() {
        if connection != 0 { IOServiceClose(connection) }
        connection = 0
        request?.deallocate()
        reply?.deallocate()
        request = nil
        reply = nil
        sensors = []
        fans = []
        attempted = false
    }

    private func open() {
        attempted = true
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else {
            connection = 0
            return
        }
        request = .allocate(byteCount: Layout.size, alignment: 16)
        reply = .allocate(byteCount: Layout.size, alignment: 16)
        guard let count = keyCount(), count <= 16_384 else { return }
        var cpuKeys: [String] = []
        var gpuKeys: [String] = []
        for index in 0..<count {
            guard let name = keyName(at: index) else { continue }
            // Known Apple Silicon prefixes; avoid classifying unrelated TCMz/TG0B keys.
            if name.hasPrefix("Tp") || name.hasPrefix("Te") || ["TC0P", "TC0D"].contains(name) {
                cpuKeys.append(name)
            } else if name.hasPrefix("Tg") || ["TG0P", "TG0D"].contains(name) {
                gpuKeys.append(name)
            }
        }
        for (keys, cap, isGPU) in [(cpuKeys.sorted(), 7, false), (gpuKeys.sorted(), 2, true)] {
            let chosen: [String]
            if keys.count > cap {
                chosen = (0..<cap).map { keys[Int((Double($0) * Double(keys.count - 1) / Double(cap - 1)).rounded())] }
            } else { chosen = keys }
            for name in chosen {
                if let sensor = resolve(name, isGPU: isGPU) { sensors.append(sensor) }
            }
        }
        if let key = Self.fourCharCode("FNum"), let info = keyInfo(for: key),
           let count = read(key: key, dataSize: info.size, dataType: info.type), count.isFinite, count >= 0, count <= 16 {
            for index in 0..<Int(count) {
                if let fan = resolve("F\(index)Ac", isGPU: false) { fans.append(fan) }
            }
        }
    }

    private func resolve(_ name: String, isGPU: Bool) -> Sensor? {
        guard let key = Self.fourCharCode(name), let info = keyInfo(for: key),
              Self.decodableSizes.contains(info.size) else { return nil }
        return Sensor(key: key, size: info.size, type: info.type, isGPU: isGPU)
    }

    func read() -> Reading {
        if !attempted { open() }
        var cpu: [Double] = []
        var gpu: [Double] = []
        for sensor in sensors {
            guard let value = read(key: sensor.key, dataSize: sensor.size, dataType: sensor.type),
                  value.isFinite, (1...130).contains(value) else { continue }
            if sensor.isGPU { gpu.append(value) } else { cpu.append(value) }
        }
        return Reading(cpu: cpu.isEmpty ? nil : cpu.reduce(0, +) / Double(cpu.count),
                       gpu: gpu.isEmpty ? nil : gpu.reduce(0, +) / Double(gpu.count),
                       fans: fans.compactMap {
                           guard let value = read(key: $0.key, dataSize: $0.size, dataType: $0.type),
                                 value.isFinite, value >= 0, value < 60_000 else { return nil }
                           return value
                       })
    }

    // MARK: SMC transport

    /// Byte offsets into the 80-byte `AppleSMC` request/reply struct. Expressed as raw
    /// offsets rather than a Swift struct because Swift makes no guarantee that its
    /// field layout matches the C one the kernel expects, and getting that wrong would
    /// silently read the wrong bytes instead of failing.
    private enum Layout {
        static let size = 80
        static let key = 0
        static let dataSize = 28
        static let dataType = 32
        static let result = 40
        static let command = 42
        static let index = 44
        static let payload = 48
        static let payloadCapacity = 32
    }

    private enum Command {
        static let read: UInt8 = 5
        static let keyByIndex: UInt8 = 8
        static let keyInfo: UInt8 = 9
    }

    private static let decodableSizes: Set<UInt32> = [1, 2, 4]

    /// Issues one SMC transaction. Returns false when the kernel call fails or the SMC
    /// itself reports a non-zero result — an unknown key lands here, which is exactly
    /// how this degrades on hardware whose key set differs.
    @discardableResult
    private func transact(key: UInt32, command: UInt8,
                          dataSize: UInt32 = 0, dataType: UInt32 = 0, index: UInt32 = 0) -> Bool {
        guard let request, let reply, connection != 0 else { return false }

        memset(request, 0, Layout.size)
        request.storeBytes(of: key, toByteOffset: Layout.key, as: UInt32.self)
        request.storeBytes(of: dataSize, toByteOffset: Layout.dataSize, as: UInt32.self)
        request.storeBytes(of: dataType, toByteOffset: Layout.dataType, as: UInt32.self)
        request.storeBytes(of: command, toByteOffset: Layout.command, as: UInt8.self)
        request.storeBytes(of: index, toByteOffset: Layout.index, as: UInt32.self)

        var replySize = Layout.size
        let kr = IOConnectCallStructMethod(connection, 2, request, Layout.size, reply, &replySize)
        guard kr == kIOReturnSuccess, replySize == Layout.size else { return false }
        return reply.loadUnaligned(fromByteOffset: Layout.result, as: UInt8.self) == 0
    }

    private func keyCount() -> UInt32? {
        guard let key = Self.fourCharCode("#KEY"), let info = keyInfo(for: key),
              transact(key: key, command: Command.read, dataSize: info.size, dataType: info.type),
              let reply, info.size == 4 else { return nil }
        // The directory size is one of the few big-endian payloads the SMC returns.
        return UInt32(bigEndian: reply.loadUnaligned(fromByteOffset: Layout.payload, as: UInt32.self))
    }

    private func keyName(at index: UInt32) -> String? {
        guard transact(key: 0, command: Command.keyByIndex, index: index), let reply else { return nil }
        return Self.string(from: reply.loadUnaligned(fromByteOffset: Layout.key, as: UInt32.self))
    }

    private func keyInfo(for key: UInt32) -> (size: UInt32, type: UInt32)? {
        guard transact(key: key, command: Command.keyInfo), let reply else { return nil }
        let size = reply.loadUnaligned(fromByteOffset: Layout.dataSize, as: UInt32.self)
        let type = reply.loadUnaligned(fromByteOffset: Layout.dataType, as: UInt32.self)
        guard size > 0, size <= UInt32(Layout.payloadCapacity) else { return nil }
        return (size, type)
    }

    private func read(key: UInt32, dataSize: UInt32, dataType: UInt32) -> Double? {
        guard transact(key: key, command: Command.read, dataSize: dataSize, dataType: dataType),
              let reply else { return nil }
        let payload = reply.advanced(by: Layout.payload)

        return Self.decode(Data(bytes: payload, count: Int(dataSize)), type: Self.string(from: dataType))
    }

    static func decode(_ data: Data, type: String) -> Double? {
        data.withUnsafeBytes { payload in
            switch type {
            case "flt ":
                guard data.count == 4 else { return nil }
                let value = Double(Float(bitPattern: UInt32(littleEndian: payload.loadUnaligned(as: UInt32.self))))
                return value.isFinite ? value : nil
            case "ui8 ", "ui8":
                guard data.count == 1 else { return nil }
                return Double(payload.loadUnaligned(as: UInt8.self))
            case "ui16":
                guard data.count == 2 else { return nil }
                return Double(UInt16(bigEndian: payload.loadUnaligned(as: UInt16.self)))
            case "fpe2":
                guard data.count == 2 else { return nil }
                return Double(UInt16(bigEndian: payload.loadUnaligned(as: UInt16.self))) / 4.0
            case "sp78":
                guard data.count == 2 else { return nil }
                return Double(Int16(bigEndian: payload.loadUnaligned(as: Int16.self))) / 256.0
            default: return nil
            }
        }
    }

    private static func fourCharCode(_ name: String) -> UInt32? {
        let bytes = Array(name.utf8)
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func string(from code: UInt32) -> String {
        let bytes = [UInt8(truncatingIfNeeded: code >> 24), UInt8(truncatingIfNeeded: code >> 16),
                     UInt8(truncatingIfNeeded: code >> 8), UInt8(truncatingIfNeeded: code)]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }
}
