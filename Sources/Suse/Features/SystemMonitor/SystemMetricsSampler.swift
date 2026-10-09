import Foundation
import Darwin
import IOKit
import IOKit.ps
import IOKit.storage
import Metal
import SuseCore

/// All kernel and driver reads are serialized off the main actor. See ThirdPartyNotices.txt.
actor SystemMetricsSampler {
    private var processes = SystemProcessReader()
    private var previousCPU: [CPULoadTicks] = []
    private var networkCounters = SystemIOCounters()
    private var diskCounters = SystemIOCounters()
    private var previousTime: TimeInterval?
    private var diskSpace: SystemDiskSpace?
    private var diskSpaceTime: TimeInterval = -.infinity
    private let temperatures = SystemTemperatureReader()
    private var thermalTime: TimeInterval = -.infinity
    private var thermalReading = SystemTemperatureReader.Reading()
    private var gpuServices: [UInt64: io_service_t] = [:]

    deinit {
        for service in gpuServices.values { IOObjectRelease(service) }
    }

    func reset() {
        processes.reset()
        previousCPU = []
        networkCounters.reset()
        diskCounters.reset()
        previousTime = nil
        diskSpace = nil
        diskSpaceTime = -.infinity
        thermalTime = -.infinity
        temperatures.close()
        for service in gpuServices.values { IOObjectRelease(service) }
        gpuServices.removeAll()
    }

    func sample() -> SystemMetricsSnapshot {
        autoreleasepool {
            let time = ProcessInfo.processInfo.systemUptime
            let elapsed = previousTime.map { time - $0 } ?? 0
            previousTime = time
            var snapshot = SystemMetricsSnapshot()
            snapshot.sampledAt = Date()
            snapshot.uptime = time
            snapshot.sampleInterval = elapsed
            if let top = processes.read(elapsed: elapsed) {
                snapshot.processes = top
            } else {
                snapshot.notes["processes"] = "无法读取进程统计"
            }
            readCPU(into: &snapshot)
            snapshot.memory = readMemory()
            if snapshot.memory == nil { snapshot.notes["memory"] = "无法读取内存统计" }
            snapshot.gpu = readGPU()
            if snapshot.gpu == nil { snapshot.notes["gpu"] = "驱动未提供利用率，或正在建立采样基准" }
            if let counters = readNetworkCounters() {
                snapshot.network = networkCounters.sample(counters, elapsed: elapsed)
                if snapshot.network == nil { snapshot.notes["network"] = "正在建立采样基准" }
            } else {
                networkCounters.reset()
                snapshot.notes["network"] = "无法读取网络接口统计"
            }
            if let counters = readDiskCounters() {
                snapshot.diskIO = diskCounters.sample(counters, elapsed: elapsed)
                if snapshot.diskIO == nil { snapshot.notes["disk"] = "正在建立采样基准" }
            } else {
                diskCounters.reset()
                snapshot.notes["disk"] = "驱动未提供磁盘吞吐量"
            }
            if time - diskSpaceTime >= 30 {
                diskSpaceTime = time
                diskSpace = readDiskSpace()
            }
            snapshot.diskSpace = diskSpace
            if diskSpace == nil { snapshot.notes["space"] = "无法读取启动磁盘容量" }
            readBattery(into: &snapshot)
            snapshot.thermalState = ProcessInfo.processInfo.thermalState.rawValue
            if time - thermalTime >= 3 {
                thermalTime = time
                thermalReading = temperatures.read()
            }
            snapshot.cpuTemperature = thermalReading.cpu
            snapshot.gpuTemperature = thermalReading.gpu
            snapshot.fanRPM = thermalReading.fans
            if thermalReading.cpu == nil { snapshot.notes["temperature"] = "温度传感器不可用或处于休眠状态" }
            return snapshot
        }
    }

    private func readCPU(into snapshot: inout SystemMetricsSnapshot) {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else {
            previousCPU = []
            snapshot.notes["cpu"] = "无法读取 CPU 统计"
            return
        }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.size))
        }
        let states = Int(CPU_STATE_MAX)
        guard count > 0, Int(infoCount) >= Int(count) * states else {
            previousCPU = []
            snapshot.notes["cpu"] = "CPU 统计不完整"
            return
        }
        let ticks = (0..<Int(count)).map { core in
            let offset = core * states
            return CPULoadTicks(user: UInt32(bitPattern: info[offset + Int(CPU_STATE_USER)]),
                                system: UInt32(bitPattern: info[offset + Int(CPU_STATE_SYSTEM)]),
                                idle: UInt32(bitPattern: info[offset + Int(CPU_STATE_IDLE)]),
                                nice: UInt32(bitPattern: info[offset + Int(CPU_STATE_NICE)]))
        }
        defer { previousCPU = ticks }
        guard previousCPU.count == ticks.count else {
            snapshot.notes["cpu"] = "正在建立采样基准"
            return
        }
        snapshot.coreLoads = zip(ticks, previousCPU).map { $0.utilization(since: $1) }
        // Each logical core has the same scheduling window. Parked cores count as idle.
        if snapshot.coreLoads.contains(where: { $0 != nil }) {
            snapshot.cpu = snapshot.coreLoads.reduce(0) { $0 + ($1 ?? 0) } / Double(ticks.count)
        } else {
            snapshot.notes["cpu"] = "等待 CPU 计数器更新"
        }
    }

    private func readMemory() -> SystemMemory? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var pageSize: vm_size_t = 0
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0 else { return nil }
        let total = ProcessInfo.processInfo.physicalMemory
        let reclaimable = (UInt64(vm.free_count) + UInt64(vm.external_page_count)) * UInt64(pageSize)
        let used = total - min(total, reclaimable)
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let swapResult = sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        var pressure: Int32 = 0
        size = MemoryLayout<Int32>.size
        let pressureResult = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0)
        return SystemMemory(used: used, total: total, compressed: UInt64(vm.compressor_page_count) * UInt64(pageSize),
                            swap: swapResult == 0 ? swap.xsu_used : nil,
                            pressure: pressureResult == 0 ? Int(pressure) : nil)
    }

    private func readGPU() -> Double? {
        let devices = MTLCopyAllDevices()
        let ids = Set(devices.map(\.registryID))
        for id in Array(gpuServices.keys) where !ids.contains(id) {
            if let service = gpuServices.removeValue(forKey: id) { IOObjectRelease(service) }
        }
        var loads: [Double] = []
        for device in devices {
            var isNew = false
            if gpuServices[device.registryID] == nil,
               let matching = IORegistryEntryIDMatching(device.registryID) {
                let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
                if service != 0 { gpuServices[device.registryID] = service; isNew = true }
            }
            guard let service = gpuServices[device.registryID] else { continue }
            guard let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, nil, 0),
                  let stats = property.takeRetainedValue() as? [String: Any] else {
                IOObjectRelease(service)
                gpuServices.removeValue(forKey: device.registryID)
                continue
            }
            // The first read primes the driver's time-based accumulator.
            guard !isNew else { continue }
            for key in ["Device Utilization %", "Device Utilization", "GPU Activity(%)", "GPU Core Utilization"] {
                if let value = stats[key] as? NSNumber, value.doubleValue.isFinite {
                    loads.append(min(1, max(0, value.doubleValue / 100)))
                    break
                }
            }
        }
        // With multiple GPUs, report the busiest device rather than an invented combined percentage.
        return loads.max()
    }

    private func readNetworkCounters() -> [String: SystemIOCounters.Counter]? {
        // NET_RT_IFLIST2 carries 64-bit counters; getifaddrs' if_data wraps at 4 GiB.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        // Interface changes can grow the buffer between the size query and the read.
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return nil }
            var data = Data(count: size)
            let capacity = size
            let result = data.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0) }
            if result != 0 {
                if errno == ENOMEM { continue }
                return nil
            }
            guard size <= capacity else { return nil }
            data.count = size
            return Self.parseNetworkCounters(data) { index in
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                guard if_indextoname(index, &name) != nil else { return nil }
                return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return nil
    }

    nonisolated static func parseNetworkCounters(_ data: Data, interfaceName: (UInt32) -> String?) -> [String: SystemIOCounters.Counter]? {
        data.withUnsafeBytes { bytes in
            var counters: [String: SystemIOCounters.Counter] = [:]
            var offset = 0
            while offset < bytes.count {
                // All routing messages share only this 4-byte prefix. Address messages
                // have a shorter header than if_msghdr; inspect type before decoding.
                guard bytes.count - offset >= 4 else { return nil }
                let length = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                let version = bytes[offset + 2]
                let type = bytes[offset + 3]
                guard length >= 4, length <= bytes.count - offset, version == RTM_VERSION else { return nil }
                defer { offset += length }
                guard type == RTM_IFINFO2 else { continue }
                guard length >= MemoryLayout<if_msghdr2>.size else { return nil }
                let info = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                guard info.ifm_flags & IFF_UP != 0, info.ifm_flags & IFF_RUNNING != 0,
                      info.ifm_flags & IFF_LOOPBACK == 0,
                      let interface = interfaceName(UInt32(info.ifm_index)), interface.hasPrefix("en") else { continue }
                // Physical Ethernet/Wi-Fi only; tunnels and bridges count traffic twice.
                counters[interface] = .init(incoming: info.ifm_data.ifi_ibytes, outgoing: info.ifm_data.ifi_obytes)
            }
            return counters
        }
    }

    private func readDiskCounters() -> [String: SystemIOCounters.Counter]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var counters: [String: SystemIOCounters.Counter] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS,
                  let property = IORegistryEntryCreateCFProperty(service, kIOBlockStorageDriverStatisticsKey as CFString, nil, 0),
                  let stats = property.takeRetainedValue() as? [String: Any],
                  let read = stats[kIOBlockStorageDriverStatisticsBytesReadKey] as? NSNumber,
                  let written = stats[kIOBlockStorageDriverStatisticsBytesWrittenKey] as? NSNumber else { continue }
            counters[String(id)] = .init(incoming: read.uint64Value, outgoing: written.uint64Value)
        }
        return counters.isEmpty ? nil : counters
    }

    private func readDiskSpace() -> SystemDiskSpace? {
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity,
              total > 0, available >= 0 else { return nil }
        return SystemDiskSpace(total: UInt64(total), available: min(UInt64(total), UInt64(available)))
    }

    private func readBattery(into snapshot: inout SystemMetricsSnapshot) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            snapshot.notes["battery"] = "无法读取电源状态"
            return
        }
        let battery = sources.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }.first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
        guard let battery else { snapshot.notes["battery"] = "此 Mac 没有内置电池"; return }
        guard let current = battery[kIOPSCurrentCapacityKey] as? NSNumber,
              let maximum = battery[kIOPSMaxCapacityKey] as? NSNumber, maximum.doubleValue > 0 else {
            snapshot.notes["battery"] = "电池容量不可用"
            return
        }
        snapshot.battery = SystemBattery(fraction: min(1, max(0, current.doubleValue / maximum.doubleValue)),
                                        charging: battery[kIOPSIsChargingKey] as? Bool ?? false,
                                        pluggedIn: battery[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
    }
}
