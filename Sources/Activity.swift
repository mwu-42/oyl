import Darwin
import IOKit
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
        /// The chip's and the battery's temperatures, in °C (see `Thermals`).
        var chipTemp: Double?
        var batteryTemp: Double?
    }

    /// (Set only by sampling, and by the tests' pictures.)
    @Published var snapshot = Snapshot()
    /// Recent CPU readings, oldest first, for the graph.
    @Published var history: [Double] = []

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
    private let sensors = Thermals.Sensors()
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
        let thermals = Thermals.pick(sensors.read())
        (snapshot.chipTemp, snapshot.batteryTemp) = (thermals.chip, thermals.battery)
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

/// The computer page: the processor, memory, network, battery and temperatures, and the busiest
/// apps, all in its pink.
struct ActivityPage: View {
    @ObservedObject var stats: SystemStats

    /// The page's pink, for every meter, graph and figure on it.
    static let tint = Color(red: 1, green: 0.42, blue: 0.74)
    @Environment(\.notchTheme) private var theme
    /// The page's pink as this look shows it (paler, in Midnight Oyl).
    private var tint: Color { theme.tint(ActivityPage.tint) }

    var body: some View {
        system
            .padding(.horizontal, 24)
            .padding(.top, 6)
            .padding(.bottom, 16)
            .onAppear { stats.start() }
            .onDisappear { stats.stop() }
    }

    var system: some View {
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
                if let chip = now.chipTemp {
                    metric("Temp") {
                        Meter(fraction: Thermals.fraction(chip)).frame(width: 92, height: 5)
                        value(Thermals.said(chip) + (now.batteryTemp.map { " · battery " + Thermals.said($0) } ?? ""))
                    }
                    .help("The chip's temperature (its dies' on average), and the battery's")
                }
            }
            // Its figures whole: the busiest apps' names give way instead.
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 4) {
                Text("Busiest")
                    .notchFont(size: 10, weight: .semibold)
                    .foregroundStyle(tint.opacity(0.7))
                ForEach(now.busiest) { process in
                    HStack(spacing: 6) {
                        Text(process.name)
                            .notchFont(size: 11, weight: .medium)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Self.percent(process.cpu))
                            .notchFont(size: 11, weight: .medium, digits: true)
                            .foregroundStyle(tint.opacity(0.8))
                    }
                }
                Spacer(minLength: 0)
                Text("Oyl: \(Self.percent(now.ownCPU)) · \(Int(now.ownMemory / 1_048_576)) MB")
                    .notchFont(size: 10, weight: .medium, digits: true)
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .help("Oyl's own share of the processor, and its memory")
            }
            .frame(maxWidth: .infinity, maxHeight: Layout.activitySystemHeight, alignment: .topLeading)  // Claude's rows under it
        }
    }

    private func metric<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .notchFont(size: 11, weight: .medium)
                .foregroundStyle(tint.opacity(0.75))
                .frame(width: 54, alignment: .leading)
            content()
        }
        .frame(height: 16)
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .notchFont(size: 11, weight: .medium, digits: true)
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

/// The Mac's own temperatures, from Apple silicon's sensors as macOS's HID event system has them
/// (read as tools like Stats read them: no privileges, no prompt), every couple of seconds while
/// the page is open: the chip, its dies on average; and the battery.
enum Thermals {
    struct Reading: Equatable {
        var chip: Double?
        var battery: Double?
    }

    /// Of what the sensors say (name, °C): the chip's dies' on average ("PMU tdie3", "PMU2
    /// tdie1"), and the battery's ("gas gauge battery"), each left out if it's past reason (one
    /// says −22° all the time).
    nonisolated static func pick(_ readings: [(name: String, celsius: Double)]) -> Reading {
        func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        let chip = readings.filter { $0.name.contains("tdie") && (10...130).contains($0.celsius) }.map(\.celsius)
        let battery = readings.filter { $0.name.hasPrefix("gas gauge battery") && (0...80).contains($0.celsius) }.map(\.celsius)
        return Reading(chip: mean(chip), battery: mean(battery))
    }

    /// How far along it is from cool (30°) to as hot as a Mac lets itself get (100°), for its meter.
    nonisolated static func fraction(_ celsius: Double) -> Double { min(max((celsius - 30) / 70, 0), 1) }

    /// "122°F", or "50°C", as the Mac's set to say temperatures.
    nonisolated static func said(_ celsius: Double) -> String {
        let formatter = MeasurementFormatter()
        formatter.numberFormatter.maximumFractionDigits = 0
        formatter.unitStyle = .medium
        return formatter.string(from: Measurement(value: celsius, unit: UnitTemperature.celsius))
    }

    /// The sensors, found once; read each time asked (on the stats' queue only).
    final class Sensors: @unchecked Sendable {
        private var services: [CFTypeRef] = []
        /// Kept, for its services to go on answering.
        private var client: CFTypeRef?

        init() {
            guard let client = hidClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return }
            self.client = client
            // Apple's own vendor page, and its temperature sensors.
            _ = hidClientSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
            services = (hidClientCopyServices(client)?.takeRetainedValue() as? [CFTypeRef]) ?? []
        }

        func read() -> [(name: String, celsius: Double)] {
            services.compactMap { service in
                guard let name = hidServiceCopyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                      let event = hidServiceCopyEvent(service, Thermals.temperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
                return (name, hidEventGetFloatValue(event, Int32(Thermals.temperatureEvent << 16)))
            }
        }
    }

    /// kIOHIDEventTypeTemperature, and its value's field is it shifted up 16.
    static let temperatureEvent: Int64 = 15
}

// IOKit's HID event system: exported, though not in its public headers.
@_silgen_name("IOHIDEventSystemClientCreate")
private func hidClientCreate(_ allocator: CFAllocator?) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func hidClientSetMatching(_ client: CFTypeRef, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func hidClientCopyServices(_ client: CFTypeRef) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func hidServiceCopyProperty(_ service: CFTypeRef, _ key: CFString) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func hidServiceCopyEvent(_ service: CFTypeRef, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventGetFloatValue")
private func hidEventGetFloatValue(_ event: CFTypeRef, _ field: Int32) -> Double

private struct Meter: View {
    @Environment(\.notchTheme) private var theme
    /// The page's pink as this look shows it.
    private var tint: Color { theme.tint(ActivityPage.tint) }
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(tint.opacity(fraction > 0.85 ? 1 : 0.85))
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
    }
}

private struct Sparkline: View {
    @Environment(\.notchTheme) private var theme
    /// The page's pink as this look shows it.
    private var tint: Color { theme.tint(ActivityPage.tint) }
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
            canvas.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.35), tint.opacity(0)]),
                                                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            canvas.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
        .background(RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.08)))
    }
}

/// The usage page: Claude Code's tokens (both accounts', see `ClaudeAccount`), each account's
/// 5-hour window, your commits, and GitHub's grid under them.
struct UsagePage: View {
    @ObservedObject var usage = TokenUsage.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ClaudeUsageRows(totals: usage.totals)
            // (The page is taller by it, so it's at the foot: see `GitHubSection.height`.)
            GitHubSection()
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 16)
        .onAppear {
            usage.start()
            CommitTimeline.shared.start()
        }
        .onDisappear {
            usage.stop()
            CommitTimeline.shared.stop()
        }
    }
}

/// Claude's part of the usage page: the graph of both accounts' tokens (see `ClaudeGraph`), and
/// each account's 5-hour window under it.
struct ClaudeUsageRows: View {
    let totals: TokenUsage.Totals?
    @ObservedObject private var limit = ClaudeLimit.shared
    @ObservedObject private var features = Features.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ClaudeGraph(totals: totals, accounts: limit.accounts)
            if features.isOn(.claudeLimit) {
                // One for each of your accounts, each in its own color, named if there's more than one.
                let several = limit.accounts.count > 1
                ForEach(Array(limit.accounts.enumerated()), id: \.element.id) { index, account in
                    ClaudeWindowRow(reading: limit.readings[account.id], account: several ? account : nil, mark: index)
                }
            }
        }
        .onAppear { limit.nudge() }
    }

    /// "$0.42", "$12.40", "$318", "$1.2k"; under a cent, "<$0.01".
    static func dollars(_ amount: Double) -> String {
        switch amount {
        case ..<0.005: return amount > 0 ? "<$0.01" : "$0"
        case ..<99.995: return String(format: "$%.2f", amount)
        case ..<999.5: return String(format: "$%.0f", amount)
        default: return String(format: "$%.1fk", amount / 1000)
        }
    }
}

/// How far back Claude's graph goes: today hour by hour, or the last week's or 30 days' days
/// (Claude Code keeps a month of chats, to begin with).
enum ClaudeSpan: String, CaseIterable {
    case today, week, month

    /// How many bars.
    var count: Int {
        switch self {
        case .today: return 24
        case .week: return 7
        case .month: return TokenUsage.days
        }
    }

    /// One account's bars: its tokens, or what they'd cost.
    func values(_ series: TokenUsage.Series, spent: Bool) -> [Double] {
        switch self {
        case .today: return spent ? series.hourlySpend : series.hourly.map(Double.init)
        case .week, .month: return Array((spent ? series.dailySpend : series.daily.map(Double.init)).suffix(count))
        }
    }

    /// One account's in all: tokens, output and what they'd cost.
    func sums(_ series: TokenUsage.Series) -> (tokens: Int, output: Int, spent: Double) {
        switch self {
        case .today: return (series.hourly.reduce(0, +), series.hourlyOutput.reduce(0, +), series.hourlySpend.reduce(0, +))
        case .week, .month:
            return (series.daily.suffix(count).reduce(0, +), series.dailyOutput.suffix(count).reduce(0, +),
                    series.dailySpend.suffix(count).reduce(0, +))
        }
    }

    /// The times under the bars, each over an even share of them: "12 AM", "6 AM"…; "Mon"…;
    /// "Oct 28"… (the last 30 days, five to each).
    func times(now: Date, calendar: Calendar = .current) -> [String] {
        let formatter = DateFormatter()
        let today = calendar.startOfDay(for: now)
        func day(_ back: Int) -> Date { calendar.date(byAdding: .day, value: -back, to: today) ?? today }
        switch self {
        case .today:
            formatter.setLocalizedDateFormatFromTemplate("j")
            return stride(from: 0, to: 24, by: 6).map { formatter.string(from: calendar.date(byAdding: .hour, value: $0, to: today) ?? today) }
        case .week:
            formatter.setLocalizedDateFormatFromTemplate("EEE")
            return (0..<7).reversed().map { $0 == 0 ? "today" : formatter.string(from: day($0)) }
        case .month:
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
            return stride(from: count - 1, through: 0, by: -5).map { formatter.string(from: day($0)) }
        }
    }
}

/// Claude Code's tokens, or what they'd have cost at Anthropic's API prices (see `ClaudePrice`),
/// big: a bar a slot (an hour today, else a day), each account's stacked on the others in its own
/// color (school in Stanford's cardinal, personal in blue, see `ClaudeWindowRow.color`), the slot
/// it is now brighter. Over it, switches for tokens or what's spent and for how far back; under
/// it, the times, then a line for each account: its tokens, output and what they'd cost.
struct ClaudeGraph: View {
    let totals: TokenUsage.Totals?
    let accounts: [ClaudeAccount]
    var now = Date()
    @AppStorage("usage.claudeSpan") private var spanName = ClaudeSpan.today.rawValue
    @AppStorage("usage.claudeSpent") private var spent = false
    @Environment(\.notchTheme) private var theme

    static let barsHeight: CGFloat = 84
    /// How tall it stands with `accounts` accounts' lines.
    static func height(accounts: Int) -> CGFloat { 16 + 6 + barsHeight + 3 + 12 + 6 + CGFloat(max(accounts, 1)) * 18 }

    var body: some View {
        let span = ClaudeSpan(rawValue: spanName) ?? .today
        let midnight = theme == .midnight
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Claude")
                    .notchFont(size: 11, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 4)
                UsageSwitch(options: ["tokens", "spent"], picked: spent ? 1 : 0) { spent = $0 == 1 }
                    .help("Tokens (input, output and cache writes), or what they'd cost at Anthropic's API prices (a subscription doesn't charge by the token)")
                UsageSwitch(options: ClaudeSpan.allCases.map(\.rawValue), picked: ClaudeSpan.allCases.firstIndex(of: span) ?? 0) {
                    spanName = ClaudeSpan.allCases[$0].rawValue
                }
            }
            .frame(height: 16)
            Spacer().frame(height: 6)
            bars(span, midnight: midnight)
                .frame(height: Self.barsHeight)
            Spacer().frame(height: 3)
            HStack(spacing: 0) {
                ForEach(Array(span.times(now: now).enumerated()), id: \.offset) { _, time in
                    Text(time)
                        .notchFont(size: 9, weight: .medium, digits: true)
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 12)
            Spacer().frame(height: 6)
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                legend(account, mark: index, span: span)
                    .frame(height: 18)
            }
        }
    }

    private func series(_ account: ClaudeAccount) -> TokenUsage.Series {
        totals?.accounts[account.id] ?? TokenUsage.Series()
    }

    @ViewBuilder private func bars(_ span: ClaudeSpan, midnight: Bool) -> some View {
        let columns = accounts.map { span.values(series($0), spent: spent) }
        let colors = accounts.indices.map { ClaudeWindowRow.color($0, theme: theme) }
        let count = span.count
        let sums = (0..<count).map { slot in columns.reduce(0) { $0 + ($1.indices.contains(slot) ? $1[slot] : 0) } }
        let peak = sums.max() ?? 0
        let current = span == .today ? (totals?.hour ?? Calendar.current.component(.hour, from: now)) : count - 1
        ZStack(alignment: .topLeading) {
            Canvas { canvas, size in
                let slot = size.width / CGFloat(count)
                let gap = min(slot * 0.25, 3)
                for index in 0..<count {
                    let x = CGFloat(index) * slot + gap / 2, width = slot - gap
                    guard peak > 0, sums[index] > 0 else {
                        // Nothing then: a faint tick (none yet for the hours to come).
                        if span != .today || index <= current {
                            canvas.fill(Path(CGRect(x: x, y: size.height - 1, width: width, height: 1)), with: .color(.white.opacity(0.15)))
                        }
                        continue
                    }
                    var bottom = size.height
                    for (account, column) in columns.enumerated() where column.indices.contains(index) && column[index] > 0 {
                        let height = max(size.height * CGFloat(column[index] / peak), 1.5)
                        let bar = CGRect(x: x, y: bottom - height, width: width, height: height)
                        let shade = colors[account].opacity(index == current ? 1 : midnight ? 0.7 : 0.8)
                        canvas.fill(Path(roundedRect: bar, cornerRadius: min(1.5, width / 2)), with: .color(shade))
                        bottom -= height
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(midnight ? 0.03 : 0.05)))
            if totals == nil {
                Text("Reading Claude Code's chats…")
                    .notchFont(size: 11, weight: .medium)
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if peak > 0 {
                // The tallest, at the top.
                Text(spent ? ClaudeUsageRows.dollars(peak) : ActivityPage.tokens(Int(peak)))
                    .notchFont(size: 9, weight: .medium, digits: true)
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.leading, 4)
                    .padding(.top, 2)
            }
        }
    }

    private func legend(_ account: ClaudeAccount, mark: Int, span: ClaudeSpan) -> some View {
        let sums = span.sums(series(account))
        let color = ClaudeWindowRow.color(mark, theme: theme)
        return HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 8, height: 8)
            Text(account.name)
                .notchFont(size: 11, weight: .semibold)
                .foregroundStyle(color)
                .frame(width: 58, alignment: .leading)
            Text("\(ActivityPage.tokens(sums.tokens)) tokens · \(ActivityPage.tokens(sums.output)) out · \(ClaudeUsageRows.dollars(sums.spent))")
                .notchFont(size: 11, weight: .medium, digits: true)
                .foregroundStyle(.white.opacity(sums.tokens > 0 ? 0.85 : 0.4))
                .lineLimit(1)
        }
    }
}

/// A few words, one of them picked: the others dim, a click picks another. In Midnight's look in
/// its italics.
struct UsageSwitch: View {
    let options: [String]
    let picked: Int
    let pick: (Int) -> Void
    @Environment(\.notchTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                Button { pick(index) } label: {
                    Text(option)
                        .font(theme == .midnight ? Midnight.italic(11.5) : .system(size: 10.5, weight: index == picked ? .semibold : .medium))
                        .foregroundStyle(.white.opacity(index == picked ? 0.95 : 0.4))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// How much of Claude's 5-hour limit window is used (see `ClaudeLimit`), in its account's color: a
/// bar filling in Oyl's look, a moon waxing in Midnight's; the figure, and when it resets. With
/// more than one account, a row for each: "5 hours" over them, each named (see `color`).
struct ClaudeWindowRow: View {
    let reading: ClaudeLimit.Reading?
    /// Whose it is, if it's one of several; and which of them (for its color, and "5 hours" on
    /// the first).
    var account: ClaudeAccount? = nil
    var mark = 0
    var now = Date()
    @Environment(\.notchTheme) private var theme

    /// An account's color, by its place among them: Claude Code's own (school) in Stanford's
    /// cardinal (a shade lighter, to read on black), then blue (personal), mint, lavender.
    static func hue(_ mark: Int) -> Color {
        let hues = [Color(red: 0.78, green: 0.13, blue: 0.18), Color(red: 0.36, green: 0.62, blue: 1), Color(red: 0.5, green: 0.9, blue: 0.68),
                    Color(red: 0.74, green: 0.62, blue: 1)]
        return hues[((mark % hues.count) + hues.count) % hues.count]
    }

    /// As this look shows it: in Midnight's paled, but less than its accents are, so the cardinal
    /// stays red rather than going pink.
    static func color(_ mark: Int, theme: NotchTheme) -> Color {
        theme == .midnight ? Midnight.pale(hue(mark), keep: 0.6) : hue(mark)
    }

    var body: some View {
        // The window in its account's color.
        let label = Color.white.opacity(0.55)
        let color = Self.color(mark, theme: theme)
        let reading = self.reading.flatMap { $0.isCurrent(at: now) ? $0 : nil }
        let fraction = reading.map { min(max(Double($0.percent) / 100, 0), 1) } ?? 0
        return HStack(spacing: 8) {
            Text(mark == 0 ? "5 hours" : "")
                .notchFont(size: 11, weight: .medium)
                .foregroundStyle(label.opacity(0.85))
                .frame(width: 54, alignment: .leading)
            Group {
                if theme == .midnight {
                    WaxingMoon(fraction: fraction)
                        .fill(color.opacity(0.9))
                        .background(Circle().strokeBorder(color.opacity(0.3), lineWidth: 0.75))
                        .shadow(color: color.opacity(0.2 + 0.4 * fraction), radius: 2 + 3 * fraction)
                        .frame(width: 13, height: 13)
                        .frame(width: 92, alignment: .leading)
                } else {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(color.opacity(0.18))
                            Capsule().fill(color).frame(width: geometry.size.width * fraction)
                        }
                    }
                    .frame(width: 92, height: 5)
                }
            }
            HStack(spacing: 6) {
                if let account {
                    Text(account.name)
                        .notchFont(size: 11, weight: .semibold)
                        .foregroundStyle(color)
                }
                Text(reading.map(ClaudeLimit.short) ?? "not read yet")
                    .notchFont(size: 11, weight: .medium, digits: true)
                    .foregroundStyle(color.opacity(reading == nil ? 0.5 : 0.95))
                    .contentTransition(.numericText(value: Double(reading?.percent ?? 0)))
            }
            .lineLimit(1)
        }
        .frame(height: 16)
        .animation(theme == .midnight ? .timingCurve(0.45, 0, 0.25, 1, duration: 1.2) : .easeOut(duration: 0.3), value: reading?.percent)
        .help(reading.map { ClaudeLimit.describe($0, account: account) }
              ?? "\(account.map { "Your \($0.name) account's" } ?? "Claude's") 5-hour limit window, as Claude Code's /usage says")
        // Right-click: where else it shows, and starting it early.
        .contentShape(Rectangle())
        .settingsMenu(.notch) {
            FeatureToggle(.claudeLimitBar, "On the bar, beside the notch (what's left)")
            FeatureToggle(.morningClaude, "Started early each morning, at \(MorningStart.shared.time)")
            FeatureToggle(.claudeChain, "Started again as each one ends, till 2 AM")
            FeatureToggle(.claudeLimit, "Here, on the usage page")
        }
    }

}

/// Your commits today, hour by hour (see `CommitTimeline`), as Claude's tokens are above it: the
/// bars, how many today and in the last five hours, and the repository with the most.
struct CommitRow: View {
    @ObservedObject private var commits = CommitTimeline.shared
    var span = GitHubSpan.year
    /// Shown in place of what's read (for a picture of it).
    var given: CommitTimeline.Totals? = nil
    @Environment(\.notchTheme) private var theme
    private var tint: Color { GitHubGreen.bright(theme) }

    var body: some View {
        let totals = given ?? commits.totals
        HStack(spacing: 8) {
            Text("Commits")
                .notchFont(size: 11, weight: .medium)
                .foregroundStyle(tint.opacity(0.8))
                .frame(width: 54, alignment: .leading)
            SlotBars(values: totals?.bars(span) ?? [], current: (totals?.bars(span).count ?? 0) - 1, tint: tint)
                .frame(width: 128, height: 16)
            Text(Self.says(totals, span: span))
                .notchFont(size: 11, weight: .medium, digits: true)
                .foregroundStyle(.white.opacity(totals?.repositories == 0 ? 0.45 : 0.85))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let busiest = totals?.busiestIn[span] {
                HStack(spacing: 3) {
                    Image(systemName: "folder")
                        .notchSymbol(size: 8, weight: .semibold)
                    Text(busiest)
                        .notchFont(size: 10, weight: .medium)
                        .lineLimit(1)
                }
                .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(height: 16)
        .contentShape(Rectangle())
        .help("Your commits, from the git repositories Claude Code's worked in (\(totals?.repositories ?? 0) of them)")
        .settingsMenu(.notch) { FeatureToggle(.commitTimeline, "Commits here") }
    }

    /// "12 today · 3 last 5 h"; before any's read, or with none to read.
    static func says(_ totals: CommitTimeline.Totals?) -> String {
        guard let totals else { return "Reading git…" }
        guard totals.repositories > 0 else { return "No repositories yet" }
        guard totals.today > 0 || totals.lastFiveHours > 0 else { return "None today" }
        return "\(totals.today) today · \(totals.lastFiveHours) last 5 h"
    }

    /// "34 past week · 5 today"; "120 past month"; before any's read, or with none to read.
    static func says(_ totals: CommitTimeline.Totals?, span: GitHubSpan) -> String {
        guard let totals else { return "Reading git…" }
        guard totals.repositories > 0 else { return "No repositories yet" }
        let count = totals.count(in: span)
        guard count > 0 else { return "None, the \(span.said)" }
        return "\(count) \(span.said)" + (span == .week && totals.today > 0 ? " · \(totals.today) today" : "")
    }
}

/// GitHub's part of the usage page, in its green: its name and how far back (the past week,
/// month or year, remembered), your commits, then its grid.
struct GitHubSection: View {
    @ObservedObject private var features = Features.shared
    @AppStorage("usage.githubSpan") private var spanName = GitHubSpan.year.rawValue
    @Environment(\.notchTheme) private var theme

    /// How tall it is, with what's on (none of it: nothing).
    static var height: CGFloat {
        let grid = Feature.githubGrid.isOn, commits = Feature.commitTimeline.isOn
        guard grid || commits else { return 0 }
        return 8 + 16 + (commits ? 24 : 0) + (grid ? 8 + Layout.githubHeight : 0)
    }

    var body: some View {
        let span = GitHubSpan(rawValue: spanName) ?? .year
        if features.isOn(.githubGrid) || features.isOn(.commitTimeline) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text("GitHub")
                        .notchFont(size: 11, weight: .semibold)
                        .foregroundStyle(GitHubGreen.bright(theme))
                    Spacer(minLength: 4)
                    UsageSwitch(options: GitHubSpan.allCases.map(\.rawValue), picked: GitHubSpan.allCases.firstIndex(of: span) ?? 2) {
                        spanName = GitHubSpan.allCases[$0].rawValue
                    }
                }
                .frame(height: 16)
                if features.isOn(.commitTimeline) { CommitRow(span: span) }
                if features.isOn(.githubGrid) { GitHubRow(span: span) }
            }
            .padding(.top, 8)
        }
    }
}

/// A bar a slot (an hour, a day, a week), the one it is now brighter; one with none, a faint tick.
private struct SlotBars: View {
    let values: [Int]
    let current: Int
    let tint: Color

    var body: some View {
        Canvas { canvas, size in
            let peak = CGFloat(max(values.max() ?? 0, 1))
            let count = max(values.count, 1)
            let slot = size.width / CGFloat(count)
            for index in 0..<count {
                let value = index < values.count ? CGFloat(values[index]) : 0
                let height = value > 0 ? max(size.height * value / peak, 2) : 1
                let gap = min(1, slot * 0.25)
                let bar = CGRect(x: CGFloat(index) * slot + gap / 2, y: size.height - height, width: slot - gap, height: height)
                let opacity = value > 0 ? (index == current ? 1 : 0.6) : (index == current ? 0.5 : 0.15)
                canvas.fill(Path(bar), with: .color(tint.opacity(opacity)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.08)))
    }
}
