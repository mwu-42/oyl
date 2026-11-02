import AppKit
import ApplicationServices

/// What a coding agent is doing, going by its latest hook event.
enum AgentActivity: Equatable, Sendable {
    case idle        // between turns
    case thinking    // on a prompt, between tools
    case coding      // editing or writing files
    case running     // running a command
    case reading     // reading or searching the code
    case browsing    // on the web
    case delegating  // handed work to a subagent
    case writing     // a chat in the Claude app, writing its reply
    case waiting     // needs you: a permission prompt, a question, a plan to review
    case done        // just finished its turn

    var title: String {
        switch self {
        case .idle: return "Idle"
        case .thinking: return "Thinking"
        case .coding: return "Writing code"
        case .running: return "Running a command"
        case .reading: return "Reading"
        case .browsing: return "Browsing the web"
        case .delegating: return "Working with a subagent"
        case .writing: return "Writing a reply"
        case .waiting: return "Waiting for you"
        case .done: return "Done"
        }
    }

    /// Which agent the closed notch shows when there are several.
    var priority: Int {
        switch self {
        case .waiting: return 3
        case .thinking, .coding, .running, .reading, .browsing, .delegating, .writing: return 2
        case .done: return 1
        case .idle: return 0
        }
    }
}

struct AgentSession: Identifiable, Equatable {
    let id: String          // Claude Code's session ID
    var project: String     // the folder it's working in
    var cwd: String?        // …in full
    var host: String?       // the app it runs in, like "VS Code"
    var activity: AgentActivity
    var detail: String?     // what exactly, like "Editing NotchView.swift"
    var since: Date         // when the current activity began
    var lastEvent: Date
    var pid: Int32          // the agent's process, 0 if unknown
    var skin = 0            // its Oyl's pastel, see `Oyl.pastel(_:)`
    var isClaude = true     // Claude's, so its Oyl wears Claude's cap (Muse's doesn't)

    var summary: String { detail ?? activity.title }
}

/// Follows coding agents through Claude Code's hooks: every hook event runs a small script
/// (`AgentInbox.hookScript`) that drops the event in a folder, and Oyl reads and deletes them.
/// An agent goes away with Claude Code's SessionEnd event, or when its process is gone. Chats in
/// the Claude app come from `ClaudeAppChats`, each of its Cowork tasks from `CoworkTasks`, and
/// agents in a browser tab (Muse) from `WebAgents`.
@MainActor
final class AgentMonitor: ObservableObject {
    /// In the order they first showed up.
    @Published private(set) var sessions: [AgentSession] = []
    /// The Claude app is installed but Oyl can't read its window yet.
    @Published private(set) var offersChats = false
    /// Agents waiting for your OK, oldest first.
    @Published private(set) var approvals: [Approval] = []
    /// Oyl's switched off: Claude Code asks for its OKs the usual way, straight off, rather than
    /// waiting on a notch no one can see. Those already waiting are handed back.
    var isAway = false {
        didSet {
            guard isAway != oldValue else { return }
            AgentInbox.setAway(isAway)
            guard isAway else { return }
            codeApprovals.forEach { AgentInbox.answer($0.id, allow: nil) }
            codeApprovals = []
            updateApprovals()
        }
    }

    private static let chatID = "claude-app"
    private var codeApprovals: [Approval] = []
    private var appApproval: Approval?
    private var appApprovalDismissed = false
    private var appApprovalTimeout: DispatchWorkItem?
    private lazy var chats = ClaudeAppChats { [weak self] chat in
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self?.apply(chat) }
        }
    }
    private lazy var cowork = CoworkTasks { [weak self] tasks in
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self?.apply(tasks) }
        }
    }
    private lazy var web = WebAgents { [weak self] agents in
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self?.apply(agents) }
        }
    }
    /// What the Claude app's window last showed, to tell its Cowork task from a chat.
    private var lastChat: ClaudeAppChats.Chat?
    private static let coworkPrefix = "cowork:", webPrefix = "web:"

    private let queue = DispatchQueue(label: "oyl.Agents", qos: .utility)
    private let scripts = ScriptRunner()
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var sweep: Timer?

    init() {
        AgentInbox.prepare()
        AgentInbox.preparePermissions()
        // Events can be large (a file being written comes with its contents), so they're read
        // off the main thread.
        watch(AgentInbox.folder) { [weak self] in
            let events = AgentInbox.drain()
            guard !events.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(events) }
            }
        }
        watch(AgentInbox.requests) { [weak self] in
            let requests = AgentInbox.waitingRequests()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, requests != self.codeApprovals else { return }
                    // Asked just as Oyl was switched off.
                    if self.isAway {
                        requests.forEach { AgentInbox.answer($0.id, allow: nil) }
                        return
                    }
                    self.codeApprovals = requests
                    self.updateApprovals()
                }
            }
        }
        sweep = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tidy() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == ClaudeAppChats.bundleID else { return }
                MainActor.assumeIsolated { self?.followClaudeApp() }
            }
        }
        followClaudeApp()
    }

    /// Runs `changed` (on `queue`) whenever files come or go in `folder`.
    private func watch(_ folder: URL, changed: @escaping @Sendable () -> Void) {
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: queue)
        source.setEventHandler(handler: changed)
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watchers.append(source)
    }

    /// The Claudes at work, for the closed notch: any that's busy or needs you. One that's done
    /// walks off instead.
    var working: [AgentSession] {
        sessions.filter { $0.activity.priority > 1 }
    }

    func answer(_ approval: Approval, allow: Bool) {
        switch approval.source {
        case .claudeCode:
            AgentInbox.answer(approval.id, allow: allow)
            codeApprovals.removeAll { $0.id == approval.id }
        case .claudeApp:
            chats.respond(allow: allow)
            appApproval = nil
        }
        updateApprovals()
    }

    /// Leaves the request to be answered where the agent is, and goes there.
    func answerInApp(_ approval: Approval) {
        switch approval.source {
        case .claudeCode:
            AgentInbox.answer(approval.id, allow: nil)
            codeApprovals.removeAll { $0.id == approval.id }
        case .claudeApp:
            appApproval = nil
            appApprovalDismissed = true
        }
        if let session = sessions.first(where: { $0.id == approval.session }) { reveal(session) }
        updateApprovals()
    }

    /// Claude Code's requests name only the session; its project and app come from there.
    private func updateApprovals() {
        let named = codeApprovals.map { approval in
            guard let session = sessions.first(where: { $0.id == approval.session }) else { return approval }
            return Approval(id: approval.id, source: approval.source, session: approval.session, project: session.project,
                            host: session.host, action: approval.action, detail: approval.detail)
        }
        let all = named + [appApproval].compactMap { $0 }
        if all != approvals { approvals = all }
    }

    /// Sets the sessions, and sends off any that has just finished.
    private func publish(_ sessions: [AgentSession]) {
        var sessions = sessions
        paint(&sessions)
        guard sessions != self.sessions else { return }
        self.sessions = sessions
    }

    /// Gives each new task's Oyl a pastel none of the others has.
    private func paint(_ sessions: inout [AgentSession]) {
        let known = Set(self.sessions.map(\.id))
        var taken = Set(sessions.filter { known.contains($0.id) }.map(\.skin))
        for index in sessions.indices where !known.contains(sessions[index].id) {
            sessions[index].skin = Oyl.pastel(for: sessions[index].id, avoiding: taken)
            taken.insert(sessions[index].skin)
        }
    }

    /// Asks for Accessibility, so chats in the Claude app show up too.
    func allowChats() {
        ClaudeAppChats.requestAccess()
    }

    /// Watches the Claude app while it's open and Oyl may read it. Checked again every few
    /// seconds, since access can be allowed at any time.
    private func followClaudeApp() {
        let allowed = AXIsProcessTrusted()
        let offers = !allowed && ClaudeAppChats.isInstalled
        if offers != offersChats { offersChats = offers }
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeAppChats.bundleID).first
        chats.follow(app?.processIdentifier, allowed: allowed)
        cowork.follow(app != nil)
        web.follow(allowed: allowed)
    }

    /// The Claude app's Cowork tasks, each its own Oyl: Claude's, in the app. One that's stopped
    /// working has just finished; one the app's window is asking about wants you.
    private func apply(_ tasks: [CoworkTasks.Task]) {
        let now = Date()
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeAppChats.bundleID).first?.processIdentifier ?? 0
        var sessions = self.sessions.filter { session in
            !session.id.hasPrefix(Self.coworkPrefix) || tasks.contains { Self.coworkPrefix + $0.id == session.id }
        }
        for task in tasks {
            let id = Self.coworkPrefix + task.id
            let index = sessions.firstIndex { $0.id == id }
            var session = index.map { sessions[$0] }
                ?? AgentSession(id: id, project: task.title, cwd: nil, host: "Cowork", activity: task.activity, detail: nil,
                                since: now, lastEvent: task.lastActivity, pid: pid)
            session.project = task.title
            session.lastEvent = task.lastActivity
            if pid > 0 { session.pid = pid }
            var activity = task.activity
            if let chat = lastChat, chat.needsApproval, chat.title == task.title { activity = .waiting }
            if activity == .idle, index != nil, session.activity != .idle, session.activity != .done { activity = .done }
            if activity != session.activity, !(activity == .idle && session.activity == .done) {
                session.activity = activity
                session.since = now
            }
            if let index { sessions[index] = session } else { sessions.append(session) }
        }
        publish(sessions)
    }

    /// Agents in a browser tab, each its own Oyl while it's at work; done, it cheers and goes
    /// (see `tidy`), and comes back the next time it's at work.
    private func apply(_ agents: [WebAgents.Agent]) {
        let now = Date()
        var sessions = self.sessions.filter { session in
            !session.id.hasPrefix(Self.webPrefix) || agents.contains { Self.webID($0) == session.id }
        }
        for agent in agents {
            let id = Self.webID(agent)
            let index = sessions.firstIndex { $0.id == id }
            guard index != nil || agent.isWorking || agent.needsYou else { continue }
            var session = index.map { sessions[$0] }
                ?? AgentSession(id: id, project: agent.name, cwd: nil, host: agent.browser, activity: .idle, detail: nil,
                                since: now, lastEvent: now, pid: agent.pid, isClaude: false)
            session.pid = agent.pid
            let busy = session.activity == .browsing || session.activity == .waiting
            let activity: AgentActivity = agent.needsYou ? .waiting : agent.isWorking ? .browsing : busy ? .done : session.activity
            if activity != session.activity {
                session.activity = activity
                session.since = now
            }
            if activity != .idle { session.lastEvent = now }
            if let index { sessions[index] = session } else { sessions.append(session) }
        }
        publish(sessions)
    }

    private static func webID(_ agent: WebAgents.Agent) -> String { webPrefix + agent.browser + " " + agent.host }

    private func apply(_ chat: ClaudeAppChats.Chat?) {
        lastChat = chat
        var sessions = self.sessions
        let index = sessions.firstIndex { $0.id == Self.chatID }
        guard let chat else {
            if let index { sessions.remove(at: index) }
            publish(sessions)
            appApproval = nil
            updateApprovals()
            return
        }
        // Its own Allow and Deny buttons are up: it's waiting for you. Like Claude Code's
        // requests, the card (and the camera looking for a thumbs up) gives up after a while,
        // leaving it to be answered in the app.
        if chat.needsApproval {
            if !appApprovalDismissed, appApproval == nil {
                appApproval = Approval(id: Self.chatID, source: .claudeApp, session: Self.chatID, project: chat.title,
                                       host: "Claude app", action: "Wants your OK to use a tool", detail: nil)
                let timeout = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.appApproval != nil else { return }
                        self.appApproval = nil
                        self.appApprovalDismissed = true
                        self.updateApprovals()
                    }
                }
                appApprovalTimeout = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(AgentInbox.approvalWait), execute: timeout)
            }
        } else {
            appApprovalTimeout?.cancel()
            appApprovalTimeout = nil
            appApproval = nil
            appApprovalDismissed = false
        }
        updateApprovals()
        // A Cowork task's its own Oyl already: one asking for you is shown as waiting there.
        if let task = sessions.firstIndex(where: { $0.id.hasPrefix(Self.coworkPrefix) && $0.project == chat.title }) {
            if chat.needsApproval, sessions[task].activity != .waiting {
                sessions[task].activity = .waiting
                sessions[task].since = Date()
            }
            if let index { sessions.remove(at: index) }
            publish(sessions)
            return
        }
        // A chat shows up once Claude writes in it, and stays (idle) while the app is open.
        guard chat.isWriting || chat.needsApproval || index != nil else { return }
        let now = Date()
        var session = index.map { sessions[$0] }
            ?? AgentSession(id: Self.chatID, project: chat.title, cwd: nil, host: "Claude app", activity: .idle,
                            detail: nil, since: now, lastEvent: now, pid: chat.pid)
        session.project = chat.title
        session.pid = chat.pid
        session.lastEvent = now
        let busy = session.activity == .writing || session.activity == .waiting
        let activity: AgentActivity = chat.needsApproval ? .waiting : chat.isWriting ? .writing : busy ? .done : session.activity
        if activity != session.activity {
            session.activity = activity
            session.since = now
        }
        if let index { sessions[index] = session } else { sessions.append(session) }
        publish(sessions)
    }

    /// The one the closed notch shows: whichever needs you, else the busiest, else the latest.
    var lead: AgentSession? {
        sessions.max { ($0.activity.priority, $0.lastEvent) < ($1.activity.priority, $1.lastEvent) }
    }

    /// Brings up where the agent is working: a browser agent's tab, too.
    func reveal(_ session: AgentSession) {
        if session.id.hasPrefix(Self.webPrefix), let site = WebAgents.sites.first(where: { session.id.hasSuffix(" " + $0.host) }) {
            WebAgents.show(site.host, in: session.host ?? "")
            return
        }
        AgentWindow.reveal(session, scripts: scripts)
    }

    private func apply(_ events: [AgentEvent]) {
        var sessions = self.sessions
        let now = Date()
        for event in events {
            guard !event.ends else {
                sessions.removeAll { $0.id == event.session }
                continue
            }
            let index = sessions.firstIndex { $0.id == event.session }
            var session = index.map { sessions[$0] }
                ?? AgentSession(id: event.session, project: "Claude", cwd: nil, host: nil, activity: .idle, detail: nil,
                                since: now, lastEvent: now, pid: 0)
            if let cwd = event.cwd {
                session.cwd = cwd
                session.project = (cwd as NSString).lastPathComponent
            }
            if let host = event.host { session.host = host }
            if event.pid > 0 { session.pid = event.pid }
            session.lastEvent = now
            if let activity = event.activity {
                if activity != session.activity { session.since = now }
                session.activity = activity
                session.detail = event.detail
            }
            if let index { sessions[index] = session } else { sessions.append(session) }
        }
        publish(sessions)
        updateApprovals()
    }

    /// Drops agents whose process has quit (or, without one, that have been quiet for hours),
    /// and lets "done" settle into idle.
    private func tidy() {
        followClaudeApp()
        let now = Date()
        var sessions = self.sessions
        sessions.removeAll { session in
            session.pid > 0 ? kill(session.pid, 0) != 0 && errno == ESRCH
                            : now.timeIntervalSince(session.lastEvent) > 3 * 3600
        }
        // A browser agent's gone once it's done (it doesn't wait about, the way Claude Code does).
        sessions.removeAll { $0.id.hasPrefix(Self.webPrefix) && $0.activity == .done && now.timeIntervalSince($0.since) > 8 }
        for index in sessions.indices where sessions[index].activity == .done
            && now.timeIntervalSince(sessions[index].since) > 8 {
            sessions[index].activity = .idle
            sessions[index].detail = nil
            sessions[index].since = now
        }
        publish(sessions)
    }
}

/// One hook event, boiled down to what the notch shows.
struct AgentEvent: Sendable {
    let session: String
    let ends: Bool
    let cwd: String?
    let host: String?
    let pid: Int32
    let activity: AgentActivity?  // nil when the event doesn't change it
    let detail: String?
}

/// The folder Claude Code's hook drops events in, and reading them back.
enum AgentInbox {
    /// Still named for the app's old name, nott: the hooks in Claude Code's settings point here.
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("nott", isDirectory: true)
    static let folder = support.appendingPathComponent("agents", isDirectory: true)
    static let hook = support.appendingPathComponent("agent-hook")

    /// Installed at every launch, so it always matches this version of Oyl. Claude Code's user
    /// settings run it for each hook event, in the background (`async`), with the event as JSON
    /// on stdin.
    static let hookScript = #"""
    #!/bin/sh
    # Oyl's Claude Code hook; Oyl rewrites this file each time it starts.
    # Drops the hook event (JSON on stdin) in Oyl's inbox, tagged with the agent's process ID,
    # so Oyl can tell when the agent quits, and the app it runs in. It prints nothing and
    # always succeeds, so it never gets in the agent's way.
    inbox="$HOME/Library/Application Support/nott/agents"
    [ -d "$inbox" ] || exit 0
    # Created first: its creation time orders events even when hooks finish out of order.
    tmp="$inbox/.$$.tmp"
    : > "$tmp" || exit 0
    pid=$PPID found=0
    for _ in 1 2 3 4; do
        case "$(ps -o comm= -p "$pid" 2>/dev/null)" in
            *claude*|*node*) found=1; break ;;
        esac
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [ -n "$pid" ] || break
    done
    [ "$found" = 1 ] || pid=0
    entry=$(printf %s "$CLAUDE_CODE_ENTRYPOINT" | tr -cd 'A-Za-z0-9._-')
    term=$(printf %s "$TERM_PROGRAM" | tr -cd 'A-Za-z0-9._-')
    { printf '{"pid":%s,"entry":"%s","term":"%s","event":' "$pid" "$entry" "$term"; cat; printf '}\n'; } > "$tmp" \
        && mv "$tmp" "$inbox/$$.json" || rm -f "$tmp"
    exit 0

    """#

    /// Creates the inbox, installs the hook, and clears out events from before this launch:
    /// agents show up again at their next event.
    static func prepare() {
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        if (try? String(contentsOf: hook, encoding: .utf8)) != hookScript {
            try? hookScript.write(to: hook, atomically: true, encoding: .utf8)
        }
        try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        for file in (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try? files.removeItem(at: file)
        }
    }

    /// Reads and deletes every waiting event, oldest first.
    static func drain() -> [AgentEvent] {
        let files = FileManager.default
        let waiting = ((try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
        let created = { (file: URL) in (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
        return waiting.sorted { created($0) < created($1) }.compactMap { file in
            defer { try? files.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let wrapper = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let hook = wrapper["event"] as? [String: Any],
                  let session = hook["session_id"] as? String,
                  let name = hook["hook_event_name"] as? String else { return nil }
            let doing = activity(after: name, hook)
            return AgentEvent(session: session, ends: name == "SessionEnd",
                              cwd: hook["cwd"] as? String,
                              host: host(entry: wrapper["entry"] as? String, term: wrapper["term"] as? String),
                              pid: Int32(wrapper["pid"] as? Int ?? 0), activity: doing?.0, detail: doing?.1)
        }
    }

    /// What the agent is doing after this event, and a line about it; nil if the event doesn't say.
    private static func activity(after name: String, _ hook: [String: Any]) -> (AgentActivity, String?)? {
        switch name {
        case "SessionStart":
            return (.idle, nil)
        case "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "SubagentStop":
            return (.thinking, nil)
        case "PreCompact":
            return (.thinking, "Compacting the conversation")
        case "PreToolUse":
            return tool(hook["tool_name"] as? String ?? "", hook["tool_input"] as? [String: Any] ?? [:])
        case "PermissionRequest":
            return (.waiting, (hook["tool_name"] as? String).map { "Asking to use \(toolName($0))" })
        case "Notification":
            // Permission prompts are announced here too. "Waiting for your input" only means
            // it's idle, which it already shows.
            let message = hook["message"] as? String ?? ""
            return message.localizedCaseInsensitiveContains("permission") ? (.waiting, message) : nil
        case "Stop":
            return (.done, nil)
        case "StopFailure":
            return (.done, "Stopped on an error")
        default:
            return nil
        }
    }

    private static func tool(_ name: String, _ input: [String: Any]) -> (AgentActivity, String?) {
        let file = (input["file_path"] as? String ?? input["notebook_path"] as? String).map { ($0 as NSString).lastPathComponent }
        let firstLine = { (text: String?) in text?.split(whereSeparator: \.isNewline).first.map(String.init) }
        switch name {
        case "Edit", "MultiEdit", "NotebookEdit":
            return (.coding, file.map { "Editing \($0)" })
        case "Write":
            return (.coding, file.map { "Writing \($0)" })
        case "Bash", "PowerShell":
            return (.running, firstLine(input["description"] as? String) ?? firstLine(input["command"] as? String).map { "Running \($0)" })
        case "Read":
            return (.reading, file.map { "Reading \($0)" })
        case "Grep", "Glob":
            return (.reading, (input["pattern"] as? String).map { "Searching for \($0)" })
        case "WebFetch":
            return (.browsing, (input["url"] as? String).flatMap { URL(string: $0)?.host }.map { "Reading \($0)" })
        case "WebSearch":
            return (.browsing, (input["query"] as? String).map { "Searching for “\($0)”" })
        case "Task", "Agent":
            return (.delegating, firstLine(input["description"] as? String))
        case "AskUserQuestion":
            return (.waiting, "Has a question for you")
        case "ExitPlanMode":
            return (.waiting, "Has a plan for you to review")
        case "TodoWrite":
            return (.thinking, "Planning")
        default:
            return (.thinking, "Using \(toolName(name))")
        }
    }

    /// MCP tools are named like "mcp__server__tool"; the server's name reads better.
    static func toolName(_ name: String) -> String {
        let parts = name.components(separatedBy: "__")
        return parts.count >= 2 && parts[0] == "mcp" ? parts[1] : name
    }

    private static func host(entry: String?, term: String?) -> String? {
        if entry?.contains("vscode") == true || term == "vscode" { return "VS Code" }
        switch term {
        case "Apple_Terminal": return "Terminal"
        case "iTerm.app": return "iTerm"
        case "ghostty": return "Ghostty"
        case "WarpTerminal": return "Warp"
        default: return nil
        }
    }
}

/// Finding the window an agent works in: the app its process runs under, and in a terminal, the
/// tab that has its tty.
enum AgentWindow {
    /// Editors that bring forward the window that has a folder open when asked to open it.
    private static let editors: Set = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
                                       "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf"]  // …Cursor, Windsurf

    @MainActor
    static func reveal(_ session: AgentSession, scripts: ScriptRunner) {
        let app = hostApp(of: session.pid)
            ?? (session.host == "VS Code" ? NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.VSCode").first : nil)
        guard let app, let appURL = app.bundleURL else { return }
        let tty = tty(of: session.pid)
        switch app.bundleIdentifier ?? "" {
        case let id where editors.contains(id):
            if let cwd = session.cwd {
                NSWorkspace.shared.open([URL(fileURLWithPath: cwd, isDirectory: true)], withApplicationAt: appURL,
                                        configuration: NSWorkspace.OpenConfiguration())
                return
            }
        case "com.apple.Terminal" where tty != nil:
            scripts.send("""
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(tty!)" then
                                set selected of t to true
                                set index of w to 1
                            end if
                        end repeat
                    end repeat
                    activate
                end tell
                """, cache: false)
            return
        case "com.googlecode.iterm2" where tty != nil:
            scripts.send("""
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(tty!)" then
                                    tell w to select
                                    tell t to select
                                    tell s to select
                                end if
                            end repeat
                        end repeat
                    end repeat
                    activate
                end tell
                """, cache: false)
            return
        default:
            break
        }
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The nearest ancestor of `pid` that's an app with windows (VS Code for its extension, Terminal
    /// for its shells).
    @MainActor
    private static func hostApp(of pid: Int32) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<12 where current > 1 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular { return app }
            guard let info = info(current) else { return nil }
            current = Int32(bitPattern: info.pbi_ppid)
        }
        return nil
    }

    /// The agent's terminal, like "/dev/ttys003"; nil when it has none (in an editor's extension).
    private static func tty(of pid: Int32) -> String? {
        guard pid > 0, let info = info(pid) else { return nil }
        let device = dev_t(bitPattern: info.e_tdev)
        guard device != -1, let name = devname(device, S_IFCHR) else { return nil }
        let tty = String(cString: name)
        return tty.hasPrefix("tty") ? "/dev/" + tty : nil
    }

    private static func info(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }
}
