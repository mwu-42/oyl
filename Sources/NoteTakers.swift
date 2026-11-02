import AppKit
import Combine

/// Apps that take notes on what they hear, like Granola in a meeting: each gets an Oyl, writing it
/// all down, for as long as it has the microphone (which macOS says of any app, without asking).
/// Which apps come from the radar (see `AgentRadar`); each's watched only while it's open.
@MainActor
final class NoteTakers: ObservableObject {
    /// The names of those taking notes now.
    @Published private(set) var taking: [String] = []

    private var watches: [String: (name: String, watch: MicWatch)] = [:]
    private var listening: Set<String> = []
    private var cancellables = Set<AnyCancellable>()

    init() {
        let radar = AgentRadar.shared
        radar.$all
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
            .store(in: &cancellables)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }
        update()
    }

    /// Oyl's resting: nothing's watched till it's back.
    var resting = false {
        didSet { if resting != oldValue { update() } }
    }

    /// Watches each note taker that's on and open; lets go of the rest.
    private func update() {
        let wanted = resting ? [] : AgentRadar.shared.watching(.microphone).filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.target).isEmpty
        }
        for (id, entry) in watches where !wanted.contains(where: { $0.target == id }) {
            entry.watch.stop()
            watches[id] = nil
            listening.remove(id)
        }
        for app in wanted where watches[app.target] == nil {
            let id = app.target
            let watch = MicWatch(bundleID: id) { [weak self] on in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.heard(id, on) }
                }
            }
            watches[id] = (app.name, watch)
            watch.start()
        }
        publish()
    }

    private func heard(_ id: String, _ on: Bool) {
        guard watches[id] != nil else { return }
        if on { listening.insert(id) } else { listening.remove(id) }
        publish()
    }

    /// Brings the note taker up.
    static func show(_ name: String) {
        guard let app = AgentRadar.shared.watching(.microphone).first(where: { $0.name == name }),
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.target).first else { return }
        running.activate()
    }

    private func publish() {
        let names = watches.filter { listening.contains($0.key) }.map(\.value.name).sorted()
        if names != taking { taking = names }
    }
}
