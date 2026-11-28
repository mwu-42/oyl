import AppKit
import Combine
import CoreAudio

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

/// An app's processes (a note-taker's, like Granola's), each watched for when it takes the microphone,
/// and the list of them watched for when they come and go. Only touched on its queue.
final class MicWatch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "oyl.MicWatch")
    private let bundleID: String
    private let changed: @Sendable (Bool) -> Void
    private var watched: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var listening: Bool?

    private static var processList = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                                mElement: kAudioObjectPropertyElementMain)
    private static var input = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                          mScope: kAudioObjectPropertyScopeGlobal,
                                                          mElement: kAudioObjectPropertyElementMain)

    /// `changed` hears whether any of the app's processes (`bundleID`, and its helpers) has the
    /// microphone, as that changes, on its queue.
    init(bundleID: String, changed: @escaping @Sendable (Bool) -> Void) {
        self.bundleID = bundleID
        self.changed = changed
    }

    private var listener: AudioObjectPropertyListenerBlock?

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            var address = Self.processList
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rescan() }
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            self.listener = listener
            rescan()
        }
    }

    /// Stops listening, saying it's off the microphone if it was on.
    func stop() {
        queue.async { [self] in
            if let listener {
                var address = Self.processList
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
                self.listener = nil
            }
            for (object, block) in watched {
                var address = Self.input
                AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
            }
            watched = [:]
            if listening == true { changed(false) }
            listening = nil
        }
    }

    /// Picks up any new process of its, lets go of those gone, and says whether it's listening.
    private func rescan() {
        let found = Set(AudioProcess.objects(matching: bundleID))
        for (object, block) in watched where !found.contains(object) {
            var address = Self.input
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
            watched[object] = nil
        }
        for object in found where watched[object] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.report() }
            var address = Self.input
            if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr { watched[object] = block }
        }
        report()
    }

    private func report() {
        let now = watched.keys.contains(where: AudioProcess.isTakingInput)
        guard now != listening else { return }
        listening = now
        changed(now)
    }
}
