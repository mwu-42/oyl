import Foundation

/// An agent waiting for your OK to use a tool.
struct Approval: Identifiable, Equatable {
    enum Source: Equatable {
        case claudeCode  // answered through `AgentInbox.permissionHook`
        case claudeApp   // a chat or Cowork in the Claude app, answered by pressing its own buttons
    }

    let id: String
    let source: Source
    let session: String?   // the agent session it belongs to
    let project: String
    let host: String?
    let action: String     // "Wants to use Bash"
    let detail: String?    // the command, file or site
}

/// Claude Code's side of approving from the notch. Its PermissionRequest hook runs
/// `permissionHook`, which leaves the request in `requests` and waits for an answer to appear
/// in `answers`, then hands it to Claude Code.
extension AgentInbox {
    static let requests = support.appendingPathComponent("requests", isDirectory: true)
    static let answers = support.appendingPathComponent("answers", isDirectory: true)
    static let permissionHook = support.appendingPathComponent("permission-hook")

    /// How long the hook waits for an answer in the notch before Claude Code asks the usual way.
    /// Its entry in Claude Code's settings needs a longer timeout than this.
    static let approvalWait = 25

    static let permissionHookScript = #"""
    #!/bin/sh
    # Oyl's Claude Code permission hook; Oyl rewrites this file each time it starts.
    # Shows the request (JSON on stdin) in the notch and waits for Allow or Deny there. With no
    # answer in time, or without Oyl running, it prints nothing, and Claude Code asks the
    # usual way.
    support="$HOME/Library/Application Support/nott"
    pgrep -xq Oyl || exit 0
    [ -d "$support/requests" ] && [ -d "$support/answers" ] || exit 0
    id="$(date +%s)-$$"
    request="$support/requests/$id.json"
    answer="$support/answers/$id.json"
    { printf '{"id":"%s","event":' "$id"; cat; printf '}\n'; } > "$support/requests/.$id.tmp" \
        && mv "$support/requests/.$id.tmp" "$request" || exit 0
    tries=$((WAIT * 4))
    while [ "$tries" -gt 0 ]; do
        if [ -f "$answer" ]; then
            cat "$answer"
            rm -f "$answer" "$request"
            exit 0
        fi
        sleep 0.25
        tries=$((tries - 1))
    done
    rm -f "$request"
    exit 0

    """#.replacingOccurrences(of: "$((WAIT * 4))", with: "\(approvalWait * 4)")

    static func preparePermissions() {
        let files = FileManager.default
        for folder in [requests, answers] {
            try? files.createDirectory(at: folder, withIntermediateDirectories: true)
            // Left from before this launch: their hooks have given up by now.
            for file in (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                try? files.removeItem(at: file)
            }
        }
        if (try? String(contentsOf: permissionHook, encoding: .utf8)) != permissionHookScript {
            try? permissionHookScript.write(to: permissionHook, atomically: true, encoding: .utf8)
        }
        try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: permissionHook.path)
    }

    /// The requests waiting now, oldest first.
    static func waitingRequests() -> [Approval] {
        let files = FileManager.default
        let waiting = ((try? files.contentsOfDirectory(at: requests, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
        let created = { (file: URL) in (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
        return waiting.sorted { created($0) < created($1) }.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let wrapper = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = wrapper["id"] as? String,
                  let hook = wrapper["event"] as? [String: Any] else { return nil }
            let tool = hook["tool_name"] as? String ?? "a tool"
            let input = hook["tool_input"] as? [String: Any] ?? [:]
            let project = (hook["cwd"] as? String).map { ($0 as NSString).lastPathComponent } ?? "Claude"
            return Approval(id: id, source: .claudeCode, session: hook["session_id"] as? String, project: project,
                            host: nil, action: "Wants to use \(toolName(tool))", detail: approvalDetail(tool, input))
        }
    }

    /// Answers a request: allow, deny, or (nil) leave it to Claude Code to ask.
    static func answer(_ id: String, allow: Bool?) {
        var reply = ""
        if let allow {
            var decision: [String: Any] = ["behavior": allow ? "allow" : "deny"]
            if !allow { decision["message"] = "Denied from Oyl" }
            let output = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
            reply = (try? JSONSerialization.data(withJSONObject: output)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        // Written whole, then moved into place, so the hook never reads half of it.
        try? reply.write(to: answers.appendingPathComponent("\(id).json"), atomically: true, encoding: .utf8)
    }

    private static func approvalDetail(_ tool: String, _ input: [String: Any]) -> String? {
        let firstLine = { (text: String?) in text?.split(whereSeparator: \.isNewline).first.map(String.init) }
        switch tool {
        case "Bash", "PowerShell": return firstLine(input["command"] as? String)
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "Read":
            return (input["file_path"] as? String ?? input["notebook_path"] as? String).map { ($0 as NSString).lastPathComponent }
        case "WebFetch": return (input["url"] as? String).flatMap { URL(string: $0)?.host }
        case "WebSearch": return input["query"] as? String
        default: return nil
        }
    }
}
