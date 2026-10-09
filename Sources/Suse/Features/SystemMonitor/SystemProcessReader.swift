import Foundation
import Darwin
import SuseCore

/// Only name, identity, CPU time and resident memory are read; no arguments or paths.
struct SystemProcessReader {
    private var counters = SystemProcessCounters()

    mutating func reset() { counters.reset() }

    mutating func read(elapsed: TimeInterval) -> [SystemProcessSample]? {
        let required = proc_listallpids(nil, 0)
        guard required > 0 else { counters.reset(); return nil }
        // Allow bounded growth while processes launch between the sizing and read calls.
        var pids = [Int32](repeating: 0, count: Int(required) + 256)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0, Int(count) <= pids.count else { counters.reset(); return nil }
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else { return nil }
        var readings: [SystemProcessCounters.Reading] = []
        readings.reserveCapacity(Int(count))
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = proc_taskallinfo()
            let size = MemoryLayout<proc_taskallinfo>.size
            guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, Int32(size)) == size else { continue }
            let start = info.pbsd.pbi_start_tvsec.multipliedReportingOverflow(by: 1_000_000)
            guard !start.overflow else { continue }
            let timestamp = start.partialValue.addingReportingOverflow(info.pbsd.pbi_start_tvusec)
            guard !timestamp.overflow else { continue }
            let identity = SystemProcessIdentity(pid: pid, startedAt: timestamp.partialValue)
            let name = withUnsafeBytes(of: info.pbsd.pbi_name) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            let fallback = withUnsafeBytes(of: info.pbsd.pbi_comm) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            let cpu = info.ptinfo.pti_total_user.addingReportingOverflow(info.ptinfo.pti_total_system)
            guard !cpu.overflow else { continue }
            // PROC_PIDTASKALLINFO exposes Mach absolute time, not nanoseconds.
            let nanoseconds = Double(cpu.partialValue) * Double(timebase.numer) / Double(timebase.denom)
            guard nanoseconds.isFinite, nanoseconds >= 0, nanoseconds < Double(UInt64.max) else { continue }
            readings.append(.init(id: identity, name: name.isEmpty ? fallback : name,
                                  cpuNanoseconds: UInt64(nanoseconds), memory: info.ptinfo.pti_resident_size))
        }
        guard !readings.isEmpty else { counters.reset(); return nil }
        return SystemProcessSample.top(counters.sample(readings, elapsed: elapsed,
                                                       coreCount: ProcessInfo.processInfo.activeProcessorCount))
    }
}
