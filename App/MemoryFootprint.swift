import Foundation
import MachO

/// Lightweight helper for sampling the current process memory usage.
enum MemoryFootprint {
    /// Returns the resident size in bytes or `nil` if sampling fails.
    static func currentResidentSize() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)

        let kernResult: kern_return_t = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    reboundPointer,
                    &count
                )
            }
        }

        guard kernResult == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
    }
}
