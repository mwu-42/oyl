import Foundation

/// Claude Code's permission hook, from when its requests for your OK were answered from Oyl. They
/// aren't any more: the hook (still named in Claude Code's settings, if it was put there) says
/// nothing, so Claude Code asks the usual way, straight off. Oyl writes it each time it starts, so
/// that entry never points at nothing, and clears away the folders requests used to wait in.
extension AgentInbox {
    static let permissionHook = support.appendingPathComponent("permission-hook")

    static let permissionHookScript = """
    #!/bin/sh
    # Oyl's Claude Code permission hook; Oyl rewrites this file each time it starts.
    # Requests for your OK aren't answered from Oyl any more: this says nothing, and Claude Code
    # asks the usual way. Its PermissionRequest entry in Claude Code's settings can go.
    exit 0

    """

    static func preparePermissions() {
        let files = FileManager.default
        for left in ["requests", "answers", "off"] { try? files.removeItem(at: support.appendingPathComponent(left)) }
        if (try? String(contentsOf: permissionHook, encoding: .utf8)) != permissionHookScript {
            try? permissionHookScript.write(to: permissionHook, atomically: true, encoding: .utf8)
        }
        try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: permissionHook.path)
    }
}
