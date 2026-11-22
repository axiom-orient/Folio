import Foundation
import Darwin
import os

/// Process accounting, not a device-wide free-RAM estimate or allocator cap.
public struct WikiProcessMemory: Codable, Sendable {
  public let residentBytes: UInt64
  public let peakResidentBytes: UInt64
  public let physicalFootprintBytes: UInt64
  public let peakPhysicalFootprintBytes: UInt64
  public let availableApplicationBytes: UInt64?

  public static func current() -> Self? {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0, let peakRSS = UInt64(exactly: usage.ru_maxrss) else { return nil }
    var info = task_vm_info_data_t()
    let words = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
    var count = mach_msg_type_number_t(words)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: words) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard status == KERN_SUCCESS,
      let peakOffset = MemoryLayout<task_vm_info_data_t>.offset(of: \.ledger_phys_footprint_peak),
      Int(count) * MemoryLayout<integer_t>.size >= peakOffset + MemoryLayout<Int64>.size,
      let peak = UInt64(exactly: info.ledger_phys_footprint_peak) else { return nil }
    #if os(iOS)
    let available: UInt64? = UInt64(os_proc_available_memory())
    #else
    let available: UInt64? = nil
    #endif
    return .init(residentBytes: info.resident_size, peakResidentBytes: peakRSS,
      physicalFootprintBytes: info.phys_footprint, peakPhysicalFootprintBytes: peak,
      availableApplicationBytes: available)
  }
}
