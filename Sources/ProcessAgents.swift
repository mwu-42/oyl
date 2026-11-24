import AppKit
import Darwin

/// Agents run as programs, in a terminal or an editor, with no hooks: Codex, Gemini CLI, Aider and
/// the rest the radar has (see `AgentRadar`), and Claude Code itself where its hooks aren't set up.
/// Each running copy is its own Oyl, named for the folder it's working in, for as long as it runs:
/// working while it's busy (an agent at its prompt uses next to nothing; one at work, streaming a
/// reply and redrawing as it goes, a steady few percent of a core), resting while it waits.
///
/// Kept light: every couple of seconds, on its own queue, one look at the processes there are (a
/// few milliseconds), reading only the names of new ones.
final class ProcessAgents: @unchecked Sendable {
    struct Program: Equatable, Sendable {
        let target: String
        let name: String
        var hat: String?
    }

    struct Agent: Equatable, Sendable {
        let pid: pid_t
        let name: String
        let target: String
        let hat: String?
        /// The folder it's working in.
        let folder: String?
        let isWorking: Bool
    }

    /// A core's share it has to be using, over the last few seconds, to be at work.
    static let busy = 0.012
    /// How long it's watched over to tell.
    static let window: TimeInterval = 4

    private let queue = DispatchQueue(label: "oyl.ProcessAgents", qos: .utility)
    private let report: @Sendable ([Agent]) -> Void
    // Only touched on `queue`.
    private var timer: DispatchSourceTimer?
    private var programs: [Program] = []
    /// What each process is, once read (nil: not one of them).
    private var names: [pid_t: (started: UInt64, program: String?)] = [:]
    /// Each one's processor time, as sampled, latest last.
    private var samples: [pid_t: [(at: TimeInterval, cpu: Double)]] = [:]
    private var last: [Agent] = []

    init(report: @escaping @Sendable ([Agent]) -> Void) {
        self.report = report
    }

    /// The programs to look for; none stops looking.
    func follow(_ programs: [Program]) {
        queue.async { [weak self] in
            guard let self else { return }
            if programs != self.programs { self.names = [:] }
            self.programs = programs
            let looking = !programs.isEmpty
            guard looking != (self.timer != nil) else { return }
            self.timer?.cancel()
            self.timer = nil
            guard looking else {
                self.samples = [:]
                self.publish([])
                return
            }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 2, leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.check() }
            timer.resume()
            self.timer = timer
        }
    }

    private func check() {
        let now = ProcessInfo.processInfo.systemUptime
        let processes = Processes.all()
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var matched: [pid_t: String] = [:]
        // (Not Oyl's own: Claude Code run for the morning's prompt, see `MorningStart`.)
        for process in processes where process.parent != getpid() {
            if let known = names[process.pid], known.started == process.started {
                if let program = known.program { matched[process.pid] = program }
                continue
            }
            let program = Processes.name(of: process.pid).flatMap { name in programs.first { $0.target == name }?.target }
            names[process.pid] = (process.started, program)
            if let program { matched[process.pid] = program }
        }
        names = names.filter { byPID[$0.key] != nil }
        var agents: [Agent] = []
        for (pid, target) in matched {
            // One that's run by another of the same (a wrapper starting the real thing) is that one.
            var parent = byPID[pid]?.parent ?? 0, wrapped = false
            for _ in 0..<4 where parent > 1 {
                if matched[parent] == target { wrapped = true; break }
                parent = byPID[parent]?.parent ?? 0
            }
            guard !wrapped, let program = programs.first(where: { $0.target == target }) else { continue }
            var history = samples[pid] ?? []
            if let cpu = Processes.cpuSeconds(of: pid) { history.append((now, cpu)) }
            history.removeAll { now - $0.at > Self.window + 2.5 }
            samples[pid] = history
            var working = false
            if let first = history.first, let latest = history.last, latest.at - first.at >= 1.5 {
                working = (latest.cpu - first.cpu) / (latest.at - first.at) >= Self.busy
            }
            agents.append(Agent(pid: pid, name: program.name, target: target, hat: program.hat,
                                folder: Processes.folder(of: pid), isWorking: working))
        }
        samples = samples.filter { matched[$0.key] != nil }
        publish(agents.sorted { $0.pid < $1.pid })
    }

    private func publish(_ agents: [Agent]) {
        guard agents != last else { return }
        last = agents
        report(agents)
    }
}

/// Apps and programs that seem to use AI: holding a connection open to one of the AI services
/// (OpenAI's, Anthropic's, Mistral's…), seen twice a minute or more apart. Each is offered once,
/// to be watched (an app by its windows, a program by how busy it is), and never again if it's
/// turned down. Browsers aren't (a browser's one app for all its tabs; their sites are watched
/// on their own), nor anything already watched.
///
/// Kept light: every half minute, on its own queue, one look at every process's connections (a
/// few milliseconds), the services' addresses looked up again every ten minutes.
final class AgentDiscovery: @unchecked Sendable {
    /// What AI services are reached at.
    static let services = [
        "api.openai.com", "api.anthropic.com", "api.mistral.ai", "api.perplexity.ai", "api.x.ai",
        "api.groq.com", "openrouter.ai", "api.together.xyz", "api.cohere.com", "api.fireworks.ai",
        "api.githubcopilot.com", "api.deepgram.com", "api.assemblyai.com", "api.elevenlabs.io",
    ]

    private let queue = DispatchQueue(label: "oyl.AgentDiscovery", qos: .background)
    private let found: @Sendable (RadarAgent) -> Void
    // Only touched on `queue`.
    private var timer: DispatchSourceTimer?
    private var addresses: Set<String> = []
    private var resolved: TimeInterval = -.infinity
    /// When each candidate was first seen.
    private var seen: [String: TimeInterval] = [:]
    /// Not to be offered: known, turned down, offered already.
    private var skip: Set<String> = []

    /// `found` gets each app or program as it's found, on `queue`.
    init(found: @escaping @Sendable (RadarAgent) -> Void) {
        self.found = found
    }

    func follow(_ looking: Bool, skipping skip: Set<String>) {
        queue.async { [weak self] in
            guard let self else { return }
            self.skip = skip
            guard looking != (self.timer != nil) else { return }
            self.timer?.cancel()
            self.timer = nil
            guard looking else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 20, repeating: 30, leeway: .seconds(5))
            timer.setEventHandler { [weak self] in self?.check() }
            timer.resume()
            self.timer = timer
        }
    }

    private func check() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - resolved > 600 {
            resolved = now
            for service in Self.services { addresses.formUnion(Processes.addresses(of: service)) }
        }
        guard !addresses.isEmpty else { return }
        let processes = Processes.all()
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var here: Set<String> = []
        for process in processes where process.pid != getpid() {
            guard !Processes.remotes(of: process.pid).isDisjoint(with: addresses),
                  let candidate = candidate(process, byPID: byPID), !skip.contains(candidate.id), !skip.contains(candidate.target)
            else { continue }
            here.insert(candidate.id)
            guard let first = seen[candidate.id] else {
                seen[candidate.id] = now
                continue
            }
            if now - first >= 60 {
                skip.insert(candidate.id)
                found(candidate)
            }
        }
        seen = seen.filter { here.contains($0.key) }
    }

    /// What's to be watched for it: a program run in a terminal, by its name; otherwise the app
    /// it belongs to (a helper's, its app's).
    private func candidate(_ process: Processes.Info, byPID: [pid_t: Processes.Info]) -> RadarAgent? {
        if process.hasTerminal, let name = Processes.name(of: process.pid), !Self.shells.contains(name), name != "claude" {
            return RadarAgent(name: name.prefix(1).uppercased() + name.dropFirst(), tell: .process, target: name)
        }
        var pid = process.pid
        for _ in 0..<8 where pid > 1 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular, let id = app.bundleIdentifier {
                guard !WebAgents.isBrowser(id), !AgentRadar.unwatchableApps.contains(id), !id.hasPrefix("com.apple.") else { return nil }
                return RadarAgent(name: app.localizedName ?? id, tell: .window, target: id)
            }
            pid = byPID[pid]?.parent ?? 0
        }
        return nil
    }

    private static let shells: Set = ["zsh", "bash", "sh", "fish", "login", "node", "python", "python3", "ruby", "bun", "deno"]
}

/// What the Mac's processes are, through the calls `ps` and `lsof` make: the user's own, which
/// need no permission.
enum Processes {
    struct Info {
        let pid: pid_t
        let parent: pid_t
        /// When it started, to tell a new process from an old one with the same ID.
        let started: UInt64
        let hasTerminal: Bool
    }

    static func all() -> [Info] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(got, 0)).compactMap { pid in
            guard pid > 0 else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid() else { return nil }
            return Info(pid: pid, parent: Int32(bitPattern: info.pbi_ppid), started: info.pbi_start_tvsec,
                        hasTerminal: info.e_tdev != UInt32.max && info.e_tdev != 0)
        }
    }

    /// What it was run as: its program's name, or for a script (run by node, python, bun…), the
    /// script's, without its extension ("gemini", "aider").
    static func name(of pid: pid_t) -> String? {
        let arguments = self.arguments(of: pid)
        guard let first = arguments.first else { return nil }
        let program = (first as NSString).lastPathComponent
        if interpreters.contains(where: { program == $0 || program.hasPrefix($0 + ".") || program.hasPrefix($0 + "3") }),
           let script = arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            let name = ((script as NSString).lastPathComponent as NSString).deletingPathExtension
            return entryPoints.contains(name) ? package(of: script) ?? name : name
        }
        return program
    }

    private static let interpreters = ["node", "python", "bun", "deno", "ruby"]
    /// What a package's script is often called, which says nothing of what it is.
    private static let entryPoints: Set = ["index", "cli", "main", "bundle", "entry"]

    /// The package a script's in, as it'd be run: ".../node_modules/@google/gemini-cli/dist/index.js"
    /// is "gemini".
    private static func package(of script: String) -> String? {
        let parts = script.split(separator: "/").map(String.init)
        guard let modules = parts.lastIndex(of: "node_modules"), modules + 1 < parts.count else { return nil }
        var name = parts[modules + 1]
        if name.hasPrefix("@"), modules + 2 < parts.count { name = parts[modules + 2] }
        return name.hasSuffix("-cli") ? String(name.dropLast(4)) : name
    }

    /// Its arguments, as it was run with.
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let count = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // The program's path, then padding, then its arguments, each ending in a zero.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < Int(count), index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    /// The folder it's working in.
    static func folder(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return path.isEmpty ? nil : path
    }

    /// How much processor time it's used, in seconds.
    static func cpuSeconds(of pid: pid_t) -> Double? {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard result == 0 else { return nil }
        return Double(usage.ri_user_time + usage.ri_system_time) * timebase / 1e9
    }

    /// Mach time to nanoseconds.
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    /// The addresses its TCP connections are open to.
    static func remotes(of pid: pid_t) -> Set<String> {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var files = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size)
        let got = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &files, size)) / MemoryLayout<proc_fdinfo>.size
        var found: Set<String> = []
        for file in files.prefix(max(got, 0)) where file.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let length = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, file.proc_fd, PROC_PIDFDSOCKETINFO, &info, length) == length,
                  info.psi.soi_kind == SOCKINFO_TCP else { continue }
            var remote = info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_faddr
            let v4 = info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_vflag & UInt8(INI_IPV4) != 0
            if let address = v4 ? string(&remote.ina_46.i46a_addr4, family: AF_INET) : string(&remote.ina_6, family: AF_INET6) {
                found.insert(address)
            }
        }
        return found
    }

    /// Every address `host` has now, as `remotes` writes them.
    static func addresses(of host: String) -> Set<String> {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0,
                             ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &list) == 0 else { return [] }
        defer { freeaddrinfo(list) }
        var found: Set<String> = []
        var entry = list
        while let current = entry?.pointee {
            if current.ai_family == AF_INET, let address = current.ai_addr {
                var inet = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                if let text = string(&inet, family: AF_INET) { found.insert(text) }
            } else if current.ai_family == AF_INET6, let address = current.ai_addr {
                var inet = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                if let text = string(&inet, family: AF_INET6) { found.insert(text) }
            }
            entry = current.ai_next
        }
        return found
    }

    /// An address as text; an IPv4 one written as IPv6 ("::ffff:1.2.3.4"), as plain IPv4.
    private static func string(_ address: inout in_addr, family: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }

    private static func string(_ address: inout in6_addr, family: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        let text = String(cString: buffer)
        if let mapped = text.split(separator: ":").last, mapped.contains(".") { return String(mapped) }
        return text
    }
}
