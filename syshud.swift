// syshud — lightweight system usage overlay for macOS.
// Build: ./build.sh   Run: ./syshud &   Stop: pkill syshud
// `./syshud --sample` prints one stats line and exits (test harness).

import AppKit
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

// MARK: - Overlay window

enum OverlayMode {
    case back   // desktop level: above wallpaper/icons, behind normal windows
    case front  // above everything, including full-screen apps
}

final class OverlayController {
    private let sampler = StatsSampler()
    private let window: NSWindow
    private let label: NSTextField
    private var timer: Timer?
    private var mode: OverlayMode

    init(mode: OverlayMode) {
        self.mode = mode
        label = NSTextField(labelWithString: "CPU –   GPU –   RAM –")
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        label.shadow = shadow

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 20),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                     .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = label
        applyLevel()
    }

    // Live-switch between front and back (triggered by SIGUSR1).
    func toggleMode() {
        mode = (mode == .back) ? .front : .back
        applyLevel()
        window.orderFrontRegardless()
    }

    private func applyLevel() {
        switch mode {
        case .back:
            window.level = NSWindow.Level(
                rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        case .front:
            window.level = .screenSaver
        }
    }

    func start() {
        _ = sampler.cpuPercent()  // prime CPU tick baseline
        layout()
        window.orderFrontRegardless()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.layout() }
    }

    private func refresh() {
        label.stringValue = sampler.line()
        layout()
    }

    // Pin the window to the top-right of the main screen, just under the
    // menu bar (visibleFrame already excludes it).
    private func layout() {
        label.sizeToFit()
        let size = label.frame.size
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let origin = NSPoint(x: vf.maxX - size.width - 12,
                             y: vf.maxY - size.height - 6)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

// MARK: - Entry point

var mode = OverlayMode.back            // default: behind windows
for arg in CommandLine.arguments.dropFirst() {
    switch arg {
    case "--sample":
        let sampler = StatsSampler()
        _ = sampler.cpuPercent()           // prime CPU tick baseline
        Thread.sleep(forTimeInterval: 1.0) // measure CPU over one second
        print(sampler.line())
        exit(0)
    case "back", "--back":
        mode = .back
    case "front", "--front":
        mode = .front
    case "toggle", "--toggle":
        // Signal the running overlay to flip front/back; exclude our own
        // pid — this toggler process is also named "syshud".
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", "syshud"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        let others = out.split(whereSeparator: \.isNewline)
            .compactMap { Int32($0) }
            .filter { $0 != getpid() }
        guard !others.isEmpty else {
            FileHandle.standardError.write(
                "syshud: no running overlay to toggle\n".data(using: .utf8)!)
            exit(1)
        }
        for pid in others { kill(pid, SIGUSR1) }
        print("syshud: toggled front/back (pid \(others.map(String.init).joined(separator: ", ")))")
        exit(0)
    default:
        FileHandle.standardError.write(
            "syshud: unknown argument '\(arg)'\nusage: syshud [back|front|toggle|--sample]\n"
                .data(using: .utf8)!)
        exit(2)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)   // no Dock icon, no menu bar, no focus
let controller = OverlayController(mode: mode)
controller.start()

// SIGUSR1 flips front/back live (sent by `syshud toggle`). The raw C
// handler must be SIG_IGN so the DispatchSource receives the signal and
// delivers it on the main queue, where AppKit calls are safe.
signal(SIGUSR1, SIG_IGN)
let toggleSignal = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
toggleSignal.setEventHandler { controller.toggleMode() }
toggleSignal.resume()

app.run()
