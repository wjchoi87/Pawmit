import Foundation
import Darwin

/// CPU·메모리·디스크 사용률. 5초에 한 번 커널 통계만 읽어서 거의 비용이 없다.
@MainActor
final class SystemMonitor {
    struct Snapshot: Equatable {
        /// 0...1
        var cpu: Double = 0
        var ram: Double = 0
        var disk: Double = 0
        var ramUsedGB: Double = 0
        var ramTotalGB: Double = 0
        var diskUsedGB: Double = 0
        var diskTotalGB: Double = 0
    }

    private(set) var latest = Snapshot()
    private var prevTicks: (busy: UInt64, total: UInt64)?
    private var lastDisk = Date.distantPast
    private var smoothedCPU = 0.0

    func sample() {
        if let cpu = cpuUsage() {
            // 순간 튐을 줄인다
            smoothedCPU = smoothedCPU == 0 ? cpu : smoothedCPU * 0.6 + cpu * 0.4
            latest.cpu = smoothedCPU
        }
        memory()
        // 디스크는 천천히 변하니 1분에 한 번
        if Date().timeIntervalSince(lastDisk) > 60 {
            lastDisk = Date()
            disk()
        }
    }

    private func cpuUsage() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1), idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        defer { prevTicks = (busy, total) }
        guard let prev = prevTicks, total > prev.total else { return nil }
        return Double(busy - prev.busy) / Double(total - prev.total)
    }

    private func memory() {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let page = UInt64(vm_kernel_page_size)
        // 활성 상태 보기의 "사용된 메모리" = 앱 메모리 + 와이어드 + 압축
        let app = UInt64(vm.internal_page_count) - min(UInt64(vm.purgeable_count), UInt64(vm.internal_page_count))
        let used = (app + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
        let total = ProcessInfo.processInfo.physicalMemory
        latest.ramUsedGB = Double(used) / 1_073_741_824
        latest.ramTotalGB = Double(total) / 1_073_741_824
        latest.ram = min(1, Double(used) / Double(max(total, 1)))
    }

    private func disk() {
        let url = FileManager.default.homeDirectoryForCurrentUser
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity, total > 0 else { return }
        let free = Double(v.volumeAvailableCapacityForImportantUsage ?? 0)
        latest.diskTotalGB = Double(total) / 1_000_000_000
        latest.diskUsedGB = (Double(total) - free) / 1_000_000_000
        latest.disk = min(1, max(0, 1 - free / Double(total)))
    }

    // MARK: - 펫 모습으로 바꾸기

    /// 더위 0...1 (CPU 30% 이하는 0, 90% 이상은 1)
    var heat: Double { ramp(latest.cpu, 0.30, 0.90) }
    /// 느림 0...1 (메모리 75% 이하는 0, 98% 이상은 1) — macOS는 평소에도 메모리를 많이 쓰므로 높게 잡는다
    var sluggish: Double { ramp(latest.ram, 0.75, 0.98) }
    /// 통통 0...1 (디스크 40% 이하는 0, 95% 이상은 1)
    var chubby: Double { ramp(latest.disk, 0.40, 0.95) }

    /// CPU 사용률을 "기온"으로: 놀 때 18℃, 꽉 차면 46℃
    var temperature: Int { Int((18 + latest.cpu * 28).rounded()) }

    /// 메모리 여유 비율을 "시속"으로: 여유 0% → 2km/h, 여유 100% → 30km/h
    var speedKmh: Int { Int((2 + (1 - latest.ram) * 28).rounded()) }

    /// 디스크 사용량을 "몸무게"로 (단위 그대로)
    var weightText: String {
        let gb = latest.diskUsedGB
        return gb >= 1000 ? String(format: "%.1fTB", gb / 1000) : "\(Int(gb.rounded()))GB"
    }

    private func ramp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        let t = min(1, max(0, (v - lo) / (hi - lo)))
        return t * t * (3 - 2 * t)
    }
}
