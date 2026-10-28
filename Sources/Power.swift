import Foundation
import IOKit.ps

/// What the battery's Oyl is doing about it.
enum PowerStatus: Equatable {
    case tired(Int)       // on battery, running low: percent left
    case recharging(Int)  // plugged in after running low
}

/// Watches the battery for its Oyl: out, tired, once it's down to 20% on battery (or plugged in
/// that low), then recharging while it's plugged in, until it's back past half.
@MainActor
final class PowerWatcher: ObservableObject {
    nonisolated static let low = 20
    nonisolated static let recovered = 50

    @Published private(set) var status: PowerStatus?
    /// Just got back past half: its Oyl cheers on the way out.
    @Published private(set) var recharged = false

    private var source: CFRunLoopSource?
    private var poll: Timer?

    init() {
        // Told of power changes as they happen, and checked every minute in case one's missed.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let watcher = Unmanaged<PowerWatcher>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.check() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            self.source = source
        }
        poll = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        check()
    }

    private func check() {
        guard let battery = Battery.read() else {
            status = nil
            return
        }
        let percent = battery.percent
        let next: PowerStatus?
        if battery.onBattery {
            next = percent <= Self.low ? .tired(percent) : nil
        } else if status != nil || percent <= Self.low {
            next = percent < Self.recovered ? .recharging(percent) : nil
        } else {
            next = nil
        }
        if case .recharging = status, next == nil, !battery.onBattery {
            recharged = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                MainActor.assumeIsolated { self?.recharged = false }
            }
        }
        if next != status { status = next }
    }
}
