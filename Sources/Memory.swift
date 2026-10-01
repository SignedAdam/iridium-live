import Darwin
import Foundation

/// How much memory the app and its engine (with the engine's own child processes) use, as Activity Monitor counts
/// it (physical footprint, which includes GPU buffers), how much the whole Mac has left, and whether the system says
/// memory is tight.
struct MemoryReading: Equatable {
    let app: UInt64
    let engine: UInt64
    let physical: UInt64
    let available: UInt64  // free, plus what the system can reclaim at once (inactive, speculative, purgeable)
    let pressured: Bool

    var total: UInt64 { app + engine }
    /// Tight when the system says so, when the Mac has under 12% of its memory left, or when we alone hold more
    /// than 40% of it.
    var warning: Bool {
        pressured || Double(available) < Double(physical) * 0.12 || Double(total) > Double(physical) * 0.4
    }
}

/// Samples memory every two seconds and on every system memory-pressure change.
@MainActor
final class MemoryMonitor {
    var onReading: (MemoryReading) -> Void = { _ in }
    private let enginePID: pid_t
    private let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
    private var pressured = false
    private var timer: Timer?

    init(enginePID: pid_t) {
        self.enginePID = enginePID
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pressured = self.pressure.data != .normal
                self.sample()
            }
        }
        pressure.activate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    private func sample() {
        let engine = Self.processTree(enginePID).reduce(0) { $0 + Self.footprint($1) }
        onReading(MemoryReading(app: Self.footprint(getpid()), engine: engine, physical: ProcessInfo.processInfo.physicalMemory,
                                available: Self.available(), pressured: pressured))
    }

    private static func available() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard status == KERN_SUCCESS else { return ProcessInfo.processInfo.physicalMemory }
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.speculative_count)
            + UInt64(stats.purgeable_count)
        return pages * UInt64(getpagesize())
    }

    private static func footprint(_ pid: pid_t) -> UInt64 {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? info.ri_phys_footprint : 0
    }

    private static func processTree(_ pid: pid_t) -> [pid_t] {
        var children = [pid_t](repeating: 0, count: 64)
        let count = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<pid_t>.size))
        return [pid] + children.prefix(max(0, Int(count))).filter { $0 > 0 }.flatMap(processTree)
    }
}
