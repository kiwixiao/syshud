// syshud — minimal macOS system usage monitor.
// Modes: menubar (default) | front | back — stats show in exactly one place.
// Build: ./build.sh   Start: syshud [mode] &   Stop: pkill syshud
// Live switch: syshud set menubar|front|back   (toggle = front<->back)
// `syshud --sample` prints one stats line and exits (test harness).

import AppKit
import Foundation
import IOKit

// MARK: - Stats model and formatting

struct Stats {
    var cpu: Double?
    var gpu: Double?
    var ram: Double?
}

func fmt(_ value: Double?) -> String {
    guard let value else { return "–" }
    return "\(Int(min(max(value, 0), 100).rounded()))%"
}

// v1 display format — used by the overlay and --sample. Do not change.
func statsLine(_ s: Stats) -> String {
    "CPU \(fmt(s.cpu))   GPU \(fmt(s.gpu))   RAM \(fmt(s.ram))"
}

// Compact menu bar title: "12 8 61" (CPU GPU RAM, no % signs).
func menubarTitle(_ s: Stats) -> String {
    [s.cpu, s.gpu, s.ram].map { v -> String in
        guard let v else { return "–" }
        return "\(Int(min(max(v, 0), 100).rounded()))"
    }.joined(separator: " ")
}

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

    func sample() -> Stats {
        Stats(cpu: cpuPercent(), gpu: gpuPercent(), ram: ramPercent())
    }

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
}

// MARK: - Display mode

enum DisplayMode: String {
    case menubar
    case front
    case back
}

// MARK: - Overlay window (display only; the coordinator feeds it stats)

final class OverlayController {
    private let window: NSWindow
    private let label: NSTextField

    init() {
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

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.layout() }
    }

    func setLevel(front: Bool) {
        window.level = front
            ? .screenSaver
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    func show() {
        layout()
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }

    func update(_ stats: Stats) {
        label.stringValue = statsLine(stats)
        layout()
    }

    // Pin to top-right of the main screen, just under the menu bar
    // (visibleFrame already excludes it).
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

// MARK: - Status item (menu bar mode)

final class StatusItemController: NSObject {
    private let item: NSStatusItem
    private let cpuRow: NSMenuItem
    private let gpuRow: NSMenuItem
    private let ramRow: NSMenuItem
    private weak var coordinator: AppCoordinator?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        cpuRow = NSMenuItem(title: "CPU –", action: nil, keyEquivalent: "")
        gpuRow = NSMenuItem(title: "GPU –", action: nil, keyEquivalent: "")
        ramRow = NSMenuItem(title: "RAM –", action: nil, keyEquivalent: "")
        super.init()

        if let button = item.button {
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.title = "– – –"
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for row in [cpuRow, gpuRow, ramRow] {
            row.isEnabled = false
            menu.addItem(row)
        }
        menu.addItem(.separator())
        menu.addItem(makeItem("Show Overlay (Front)", #selector(goFront)))
        menu.addItem(makeItem("Show Overlay (Back)", #selector(goBack)))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit syshud", #selector(quitApp), key: "q"))
        item.menu = menu
    }

    private func makeItem(_ title: String, _ action: Selector,
                          key: String = "") -> NSMenuItem {
        let m = NSMenuItem(title: title, action: action, keyEquivalent: key)
        m.target = self
        return m
    }

    func update(_ stats: Stats) {
        item.button?.title = menubarTitle(stats)
        cpuRow.title = "CPU \(fmt(stats.cpu))"
        gpuRow.title = "GPU \(fmt(stats.gpu))"
        ramRow.title = "RAM \(fmt(stats.ram))"
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    @objc private func goFront() { coordinator?.switchTo(.front) }
    @objc private func goBack() { coordinator?.switchTo(.back) }
    @objc private func quitApp() { NSApp.terminate(nil) }
}

// MARK: - Coordinator

final class AppCoordinator {
    private let sampler = StatsSampler()
    private var timer: Timer?
    private var mode: DisplayMode
    private var overlay: OverlayController?
    private var statusItem: StatusItemController?

    init(mode: DisplayMode) {
        self.mode = mode
    }

    func start() {
        _ = sampler.cpuPercent()  // prime CPU tick baseline
        applyMode()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.syshud.command"),
            object: nil, queue: .main) { [weak self] note in
            self?.handleCommand(note.object as? String ?? "")
        }
    }

    func switchTo(_ newMode: DisplayMode) {
        guard newMode != mode else { return }
        mode = newMode
        applyMode()
    }

    private func handleCommand(_ command: String) {
        switch command {
        case "toggle":
            if mode == .front { switchTo(.back) }
            else if mode == .back { switchTo(.front) }
            // menubar mode: nothing to flip — ignored
        default:
            if let m = DisplayMode(rawValue: command) { switchTo(m) }
        }
    }

    private func applyMode() {
        switch mode {
        case .menubar:
            overlay?.hide()
            overlay = nil
            if statusItem == nil {
                statusItem = StatusItemController(coordinator: self)
            }
        case .front, .back:
            statusItem?.remove()
            statusItem = nil
            if overlay == nil { overlay = OverlayController() }
            overlay?.setLevel(front: mode == .front)
            overlay?.show()
        }
        tick()
    }

    private func tick() {
        let stats = sampler.sample()
        overlay?.update(stats)
        statusItem?.update(stats)
    }
}

// MARK: - CLI helpers

func otherSyshudPids() -> [Int32] {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-x", "syshud"]
    let pipe = Pipe()
    task.standardOutput = pipe
    do { try task.run() } catch { return [] }
    task.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                     encoding: .utf8) ?? ""
    return out.split(whereSeparator: \.isNewline)
        .compactMap { Int32($0) }
        .filter { $0 != getpid() }
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

func sendCommand(_ command: String) -> Never {
    guard !otherSyshudPids().isEmpty else {
        fail("syshud: no running instance", code: 1)
    }
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("local.syshud.command"), object: command,
        userInfo: nil, deliverImmediately: true)
    print("syshud: sent '\(command)' to running instance")
    exit(0)
}

let usageText = "usage: syshud [menubar|front|back] | set <mode> | toggle | --sample"

// MARK: - Entry point

var launchMode = DisplayMode.menubar   // default: menu bar mode
let args = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < args.count {
    let arg = args[index]
    switch arg {
    case "--sample":
        let sampler = StatsSampler()
        _ = sampler.cpuPercent()           // prime CPU tick baseline
        Thread.sleep(forTimeInterval: 1.0) // measure CPU over one second
        print(statsLine(sampler.sample()))
        exit(0)
    case "menubar", "--menubar": launchMode = .menubar
    case "front", "--front": launchMode = .front
    case "back", "--back": launchMode = .back
    case "toggle", "--toggle": sendCommand("toggle")
    case "set":
        guard index + 1 < args.count,
              let m = DisplayMode(rawValue: args[index + 1]) else {
            fail(usageText, code: 2)
        }
        sendCommand(m.rawValue)
    default:
        fail("syshud: unknown argument '\(arg)'\n" + usageText, code: 2)
    }
    index += 1
}

// A running instance wins: forward the mode instead of starting a duplicate.
if !otherSyshudPids().isEmpty {
    sendCommand(launchMode.rawValue)
}

// UI must be created after the app finishes launching — a status item
// created before app.run() never gets laid out into the menu bar.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator: AppCoordinator
    init(mode: DisplayMode) {
        coordinator = AppCoordinator(mode: mode)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.start()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)    // no Dock icon; status item still works
let delegate = AppDelegate(mode: launchMode)  // global: NSApp.delegate is not retained
app.delegate = delegate
app.run()
