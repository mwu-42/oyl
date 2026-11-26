import AppKit
import os

/// Oyl's windows that are to be on every Space (`.canJoinAllSpaces`: the notch's, the desktops'
/// list, Mission Control's group marks, the lyrics), kept on every one. macOS can leave one on just
/// some of them (on just the desktop and one fullscreen app's, as it's been seen, the list brought
/// up as Mission Control was open), and nothing an app can do with the window wins the rest back:
/// ordered in again, it's up, but out of sight on every other Space. So each one's put back on the
/// Spaces it's missing as it comes in, and all of them as the Space changes, by the window server's
/// own call for it (the private one window managers use, looked up at run time: if it's ever gone,
/// nothing's done), which it allows on an app's own windows.
@MainActor
enum EverySpace {
    /// Of `all` (a display's Spaces), the ones a window that's on `have` is missing: none if it's on
    /// none (not up yet: it joins every one as it first comes in).
    nonisolated static func missing(from have: [Int], all: [Int]) -> [Int] {
        guard !have.isEmpty else { return [] }
        let had = Set(have)
        return all.filter { !had.contains($0) }
    }

    /// Every Space of `screen`'s display, by its number.
    static func spaces(on screen: NSScreen) -> [Int] {
        (FullscreenSpace.display(for: screen)?["Spaces"] as? [[String: Any]] ?? []).compactMap { $0["ManagedSpaceID"] as? Int }
    }

    /// `window` put on every Space of its screen's display (or `screen`'s) it's missing, if it's to
    /// be on all of them: the ones it's put on.
    @discardableResult
    static func rejoin(_ window: NSWindow, on screen: NSScreen? = nil) -> [Int] {
        guard let screen = screen ?? window.screen ?? NSScreen.main else { return [] }
        return rejoin(window, all: spaces(on: screen))
    }

    /// Every one of Oyl's windows that's to be on every Space, on every one (as the Space changes).
    static func rejoinAll() {
        var all: [CGDirectDisplayID: [Int]] = [:]
        for window in NSApp.windows {
            guard let screen = window.screen ?? NSScreen.main, let number = displayNumber(of: screen) else { continue }
            if all[number] == nil { all[number] = spaces(on: screen) }
            rejoin(window, all: all[number] ?? [])
        }
    }

    @discardableResult
    private static func rejoin(_ window: NSWindow, all: [Int]) -> [Int] {
        guard window.collectionBehavior.contains(.canJoinAllSpaces), window.windowNumber > 0, !all.isEmpty,
              let connection, let add else { return [] }
        let number = CGWindowID(window.windowNumber)
        let have = SpaceApps.spaces(ofWindow: number)
        let lost = missing(from: have, all: all)
        guard !lost.isEmpty else { return [] }
        let error = add(connection(), [NSNumber(value: number)] as CFArray, lost.map { NSNumber(value: $0) } as CFArray)
        log.notice("\(String(describing: type(of: window)), privacy: .public) \(Int(window.frame.width))×\(Int(window.frame.height)) was on \(have.count) of \(all.count) Spaces: put back on the other \(lost.count)\(error == 0 ? "" : " (the window server said \(error))", privacy: .public)")
        return lost
    }

    private static func displayNumber(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private typealias ConnectionID = @convention(c) () -> Int32
    private typealias AddWindows = @convention(c) (Int32, CFArray, CFArray) -> Int32
    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
    private static let connection = dlsym(defaultHandle, "CGSMainConnectionID").map { unsafeBitCast($0, to: ConnectionID.self) }
    private static let add = dlsym(defaultHandle, "CGSAddWindowsToSpaces").map { unsafeBitCast($0, to: AddWindows.self) }

    private static let log = Logger(subsystem: "local.nott", category: "spaces")
}
