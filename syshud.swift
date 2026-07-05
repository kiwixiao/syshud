// syshud — lightweight system usage overlay for macOS.
// Build: ./build.sh   Run: ./syshud &   Stop: pkill syshud
// `./syshud --sample` prints one stats line and exits (test harness).

import Foundation
import IOKit

// MARK: - Stats sampling

struct CPUTicks {
    var busy: UInt64 = 0
    var idle: UInt64 = 0
}

final class StatsSampler {
    private var prevTicks: CPUTicks?

    private static let pageSize: UInt64 = {
        var size: vm_size_t = 0
        host_page_size(mach_host_self(), &size)
        return UInt64(size)
    }()

    // CPU: aggregate busy/idle tick deltas across all cores — the same
    // kernel counters Activity Monitor reads. First call primes the
    // baseline and returns nil.
    func cpuPercent() -> Double? {
        guard let now = Self.readTicks() else { return nil }
        defer { prevTicks = now }
        guard let prev = prevTicks else { return nil }
        let busy = now.busy &- prev.busy
        let total = busy &+ (now.idle &- prev.idle)
        guard total > 0 else { return nil }
        return Double(busy) / Double(total) * 100.0
    }

    private static func readTicks() -> CPUTicks? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.size))
        }
        var ticks = CPUTicks()
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(info[base + Int(CPU_STATE_USER)])
            let system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)])
            ticks.busy &+= user &+ system &+ nice
            ticks.idle &+= UInt64(info[base + Int(CPU_STATE_IDLE)])
        }
        return ticks
    }

    // RAM: mirrors Activity Monitor "Memory Used" =
    // app memory (internal - purgeable) + wired + compressed.
    func ramPercent() -> Double? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let appPages = internalPages > purgeable ? internalPages - purgeable : 0
        let usedPages = appPages + UInt64(stats.wire_count)
                                 + UInt64(stats.compressor_page_count)
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return nil }
        return Double(usedPages * Self.pageSize) / Double(total) * 100.0
    }

    // GPU: IORegistry "IOAccelerator" service (AGXAccelerator on Apple
    // Silicon) exposes PerformanceStatistics["Device Utilization %"].
    // No root, no TCC permission needed.
    func gpuPercent() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &props,
                                                    kCFAllocatorDefault,
                                                    0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let perf = dict["PerformanceStatistics"] as? [String: Any],
                  let util = perf["Device Utilization %"] as? NSNumber
            else { continue }
            return util.doubleValue
        }
        return nil
    }

    func line() -> String {
        "CPU \(fmt(cpuPercent()))   GPU \(fmt(gpuPercent()))   RAM \(fmt(ramPercent()))"
    }

    private func fmt(_ value: Double?) -> String {
        guard let value else { return "–" }
        return "\(Int(min(max(value, 0), 100).rounded()))%"
    }
}

// MARK: - Entry point (temporary CLI-only version; overlay added next)

let sampler = StatsSampler()
_ = sampler.cpuPercent()               // prime CPU tick baseline
Thread.sleep(forTimeInterval: 1.0)     // measure CPU over one second
print(sampler.line())
