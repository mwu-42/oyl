import Darwin
import SwiftUI

/// What the Mac is doing, sampled every couple of seconds while the Activity page is open (and
/// not at all otherwise), from the same counters Activity Monitor reads.
@MainActor
final class SystemStats: ObservableObject {
    struct Process: Equatable, Identifiable {
        var id: Int32 { pid }
        let pid: Int32
        let name: String
        let cpu: Double  // 1 is one core, fully busy
    }

    struct Snapshot: Equatable {
        var cpu = 0.0           // all cores, 0...1
        var memoryUsed = 0.0    // bytes
        var memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)
        var down = 0.0, up = 0.0  // bytes a second
        var battery: Int?
        var charging = false
        var busiest: [Process] = []
        var ownCPU = 0.0        // the app itself
        var ownMemory = 0.0
    }

    @Published private(set) var snapshot = Snapshot()
    /// Recent CPU readings, oldest first, for the graph.
    @Published private(set) var history: [Double] = []

    private static let interval = 2.0
    private let sampler = Sampler()
    private let queue = DispatchQueue(label: "oyl.Activity", qos: .utility)
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        sample()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        queue.async { [weak self, sampler] in
            let snapshot = sampler.sample()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.snapshot = snapshot
                    self.history = Array((self.history + [snapshot.cpu]).suffix(30))
                }
            }
        }
    }
}

/// Reads the counters and works out rates from the last reading. Only used on its queue.
private final class Sampler: @unchecked Sendable {
    private var cpuTicks: (busy: UInt64, total: UInt64)?
    private var network: [String: (down: UInt32, up: UInt32)] = [:]
    private var processTimes: [Int32: UInt64] = [:]
    private var last: TimeInterval?
    private let timebase: (numer: Double, denom: Double) = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return (Double(info.numer), Double(info.denom))
    }()

    func sample() -> SystemStats.Snapshot {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = last.map { now - $0 } ?? 0
        last = now
        var snapshot = SystemStats.Snapshot()
        snapshot.cpu = cpu()
        (snapshot.memoryUsed, snapshot.memoryTotal) = memory()
        (snapshot.down, snapshot.up) = traffic(over: elapsed)
        if let battery = Battery.read() {
            snapshot.battery = battery.percent
            snapshot.charging = !battery.onBattery
        }
        let processes = self.processes(over: elapsed)
        snapshot.busiest = Array(processes.sorted { $0.cpu > $1.cpu }.prefix(3))
        snapshot.ownCPU = processes.first { $0.pid == getpid() }?.cpu ?? 0
        snapshot.ownMemory = ownMemory()
        return snapshot
    }

    private func cpu() -> Double {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return 0 }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        var busy: UInt64 = 0, total: UInt64 = 0
        for core in 0..<Int(count) {
            let ticks = { (state: Int32) in UInt64(UInt32(bitPattern: info[core * Int(CPU_STATE_MAX) + Int(state)])) }
            let working = ticks(CPU_STATE_USER) + ticks(CPU_STATE_SYSTEM) + ticks(CPU_STATE_NICE)
            busy += working
            total += working + ticks(CPU_STATE_IDLE)
        }
        defer { cpuTicks = (busy, total) }
        guard let previous = cpuTicks, total > previous.total else { return 0 }
        return Double(busy - previous.busy) / Double(total - previous.total)
    }

    /// Used the way Activity Monitor counts it: app memory, wired and compressed.
    private func memory() -> (Double, Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard result == KERN_SUCCESS else { return (0, total) }
        let pages = Int(stats.internal_page_count) - Int(stats.purgeable_count) + Int(stats.wire_count) + Int(stats.compressor_page_count)
        return (Double(max(pages, 0)) * Double(vm_kernel_page_size), total)
    }

    /// Wi-Fi and Ethernet (the en interfaces), so VPN traffic isn't counted twice.
    private func traffic(over elapsed: TimeInterval) -> (Double, Double) {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return (0, 0) }
        defer { freeifaddrs(addresses) }
        var current: [String: (down: UInt32, up: UInt32)] = [:]
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }).map(\.pointee) {
            guard entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            current[name] = (data.pointee.ifi_ibytes, data.pointee.ifi_obytes)
        }
        defer { network = current }
        guard elapsed > 0 else { return (0, 0) }
        var down = 0.0, up = 0.0
        for (name, now) in current {
            guard let before = network[name] else { continue }
            // The counters are 32-bit and wrap around.
            down += Double(now.down &- before.down)
            up += Double(now.up &- before.up)
        }
        return (down / elapsed, up / elapsed)
    }

    private func processes(over elapsed: TimeInterval) -> [SystemStats.Process] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [Int32](repeating: 0, count: capacity)
        let found = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<Int32>.size)))
        var times: [Int32: UInt64] = [:]
        var processes: [SystemStats.Process] = []
        for pid in pids.prefix(max(found, 0)) where pid > 0 {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
            let time = info.pti_total_user + info.pti_total_system
            times[pid] = time
            guard elapsed > 0, let before = processTimes[pid], time > before else { continue }
            let seconds = Double(time - before) * timebase.numer / timebase.denom / 1e9
            processes.append(SystemStats.Process(pid: pid, name: name(of: pid), cpu: seconds / elapsed))
        }
        processTimes = times
        return processes
    }

    private func name(of pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        let name = String(cString: buffer)
        return name.isEmpty ? "pid \(pid)" : name
    }

    private func ownMemory() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) : 0
    }
}

struct ActivityPage: View {
    @ObservedObject var stats: SystemStats
    @ObservedObject var usage = TokenUsage.shared

    /// The page's green.
    static let tint = Color(red: 0.38, green: 0.88, blue: 0.52)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            system
            claude
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 16)
        .onAppear {
            stats.start()
            usage.start()
        }
        .onDisappear {
            stats.stop()
            usage.stop()
        }
    }

    private var system: some View {
        let now = stats.snapshot
        return HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                metric("CPU") {
                    Sparkline(values: stats.history)
                        .frame(width: 92, height: 16)
                    value(Self.percent(now.cpu))
                }
                metric("Memory") {
                    Meter(fraction: now.memoryTotal > 0 ? now.memoryUsed / now.memoryTotal : 0)
                        .frame(width: 92, height: 5)
                    value(String(format: "%.1f / %.0f GB", now.memoryUsed / 1_073_741_824, now.memoryTotal / 1_073_741_824))
                }
                metric("Network") {
                    value("↓ \(Self.rate(now.down))   ↑ \(Self.rate(now.up))")
                }
                if let battery = now.battery {
                    metric("Battery") {
                        Meter(fraction: Double(battery) / 100).frame(width: 92, height: 5)
                        value("\(battery)%" + (now.charging ? " · charging" : ""))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Busiest")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Self.tint.opacity(0.7))
                ForEach(now.busiest) { process in
                    HStack(spacing: 6) {
                        Text(process.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Self.percent(process.cpu))
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(Self.tint.opacity(0.8))
                    }
                }
                Spacer(minLength: 0)
                Text("Oyl: \(Self.percent(now.ownCPU)) CPU · \(Int(now.ownMemory / 1_048_576)) MB")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity, maxHeight: Layout.activityHeight - 22, alignment: .topLeading)
        }
    }

    /// Claude Code's tokens today, hour by hour, then the totals and where most of them went.
    private var claude: some View {
        metric("Claude") {
            HourlyBars(values: usage.totals?.hourly ?? [], hour: usage.totals?.hour ?? -1)
                .frame(width: 92, height: 16)
            if let totals = usage.totals {
                if totals.today == 0 && totals.lastFiveHours == 0 {
                    Text("No Claude Code usage today")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                } else {
                    let line = "\(Self.tokens(totals.today)) today · \(Self.tokens(totals.lastFiveHours)) last 5 h"
                        + " · \(Self.tokens(totals.outputToday)) out"
                    // Without room for both, the project is left out.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            value(line)
                            Spacer(minLength: 0)
                            if let project = totals.busiestProject {
                                HStack(spacing: 3) {
                                    Image(systemName: "folder")
                                        .font(.system(size: 8, weight: .semibold))
                                    Text(project)
                                        .font(.system(size: 10, weight: .medium))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(.white.opacity(0.4))
                            }
                        }
                        value(line)
                    }
                }
            }
        }
    }

    private func metric<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Self.tint.opacity(0.75))
                .frame(width: 54, alignment: .leading)
            content()
        }
        .frame(height: 16)
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    static func rate(_ bytes: Double) -> String {
        if bytes >= 1_048_576 { return String(format: "%.1f MB/s", bytes / 1_048_576) }
        return "\(Int(bytes / 1024)) KB/s"
    }

    /// Three figures at most: 860, 4.2k, 310k, 1.24M, 12.4M.
    static func tokens(_ count: Int) -> String {
        let value = Double(count)
        switch count {
        case ..<1000: return "\(count)"
        case ..<9_950: return String(format: "%.1fk", value / 1e3)
        case ..<999_500: return String(format: "%.0fk", value / 1e3)
        case ..<9_995_000: return String(format: "%.2fM", value / 1e6)
        case ..<99_950_000: return String(format: "%.1fM", value / 1e6)
        default: return String(format: "%.0fM", value / 1e6)
        }
    }
}

private struct Meter: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(fraction > 0.85 ? Color.orange : ActivityPage.tint)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
    }
}

private struct Sparkline: View {
    let values: [Double]

    var body: some View {
        Canvas { canvas, size in
            guard values.count > 1 else { return }
            var line = Path()
            var last = CGPoint.zero
            for (index, value) in values.enumerated() {
                last = CGPoint(x: size.width * CGFloat(index) / CGFloat(29),
                               y: size.height * (1 - CGFloat(min(max(value, 0), 1))))
                if index == 0 { line.move(to: last) } else { line.addLine(to: last) }
            }
            // A soft green fill under the line.
            var area = line
            area.addLine(to: CGPoint(x: last.x, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            canvas.fill(area, with: .linearGradient(Gradient(colors: [ActivityPage.tint.opacity(0.35), ActivityPage.tint.opacity(0)]),
                                                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            canvas.stroke(line, with: .color(ActivityPage.tint), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
        .background(RoundedRectangle(cornerRadius: 3).fill(ActivityPage.tint.opacity(0.08)))
    }
}

/// A bar for each hour of the day, the hour it is now brighter. Hours without any are a faint tick.
private struct HourlyBars: View {
    let values: [Int]
    let hour: Int

    var body: some View {
        Canvas { canvas, size in
            let peak = CGFloat(max(values.max() ?? 0, 1))
            let slot = size.width / 24
            for index in 0..<24 {
                let value = index < values.count ? CGFloat(values[index]) : 0
                let height = value > 0 ? max(size.height * value / peak, 2) : 1
                let bar = CGRect(x: CGFloat(index) * slot + 0.5, y: size.height - height, width: slot - 1, height: height)
                let opacity = value > 0 ? (index == hour ? 1 : 0.55) : (index == hour ? 0.5 : 0.15)
                canvas.fill(Path(bar), with: .color(ActivityPage.tint.opacity(opacity)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 3).fill(ActivityPage.tint.opacity(0.08)))
    }
}
