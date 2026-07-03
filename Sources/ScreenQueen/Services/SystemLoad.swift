import Darwin

/// Host CPU sampling, for deciding whether the live feed should default on.
enum SystemLoad {

    /// A quick system-wide CPU busy fraction (0…1) over a brief sampling window.
    /// Blocks ~120ms — call off-main unless at a blocking-tolerant moment.
    /// `nil` if it can't be read.
    static func systemCPUUsage() -> Double? {
        func ticks() -> (busy: UInt64, total: UInt64)? {
            // HOST_CPU_LOAD_INFO_COUNT isn't exposed to Swift; derive it from the struct.
            var count = mach_msg_type_number_t(
                MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
            var info = host_cpu_load_info()
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return nil }
            let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
            let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
            let busy = user + system + nice
            return (busy, busy + idle)
        }
        guard let a = ticks() else { return nil }
        usleep(120_000)   // ~120ms sampling window
        guard let b = ticks() else { return nil }
        let dBusy = Double(b.busy &- a.busy), dTotal = Double(b.total &- a.total)
        return dTotal > 0 ? dBusy / dTotal : nil
    }
}
