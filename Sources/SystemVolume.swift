import AudioToolbox
import CoreAudio
import Foundation

/// The Mac's own output volume, the one the volume keys change, for the notch's volume controls:
/// on whichever device is playing (following it when that changes), kept up to date as it's
/// changed from elsewhere, and set straight there.
@MainActor
final class SystemVolume: ObservableObject {
    /// 0...1, and 0 while muted.
    @Published private(set) var volume: Double = 0.5

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var listener: AudioObjectPropertyListenerBlock?

    private static var defaultOutput = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                                  mElement: kAudioObjectPropertyElementMain)
    private static var level = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                          mScope: kAudioDevicePropertyScopeOutput,
                                                          mElement: kAudioObjectPropertyElementMain)
    private static var mute = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                         mScope: kAudioDevicePropertyScopeOutput,
                                                         mElement: kAudioObjectPropertyElementMain)

    init() {
        var address = Self.defaultOutput
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        follow()
    }

    /// Reads it again, for an adjustment to start from where it really is.
    func refresh() {
        guard let level = Self.read(Self.level, of: device, as: Float32.self) else { return }
        let value = Self.read(Self.mute, of: device, as: UInt32.self) == 1 ? 0 : Double(level)
        if abs(value - volume) > 0.001 { volume = value }
    }

    /// Turned up from muted, it unmutes too. Outputs without a volume of their own (some HDMI and
    /// AirPlay ones) are left as they are.
    func set(_ value: Double) {
        var level = Float32(min(max(value, 0), 1))
        var address = Self.level
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return }
        if level > 0, Self.read(Self.mute, of: device, as: UInt32.self) == 1 {
            var unmuted: UInt32 = 0, mute = Self.mute
            AudioObjectSetPropertyData(device, &mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &unmuted)
        }
        guard AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &level) == noErr else { return }
        volume = Double(level)
    }

    /// The output that's playing now, watched for its volume or mute changing.
    private func follow() {
        guard let output = Self.read(Self.defaultOutput, of: AudioObjectID(kAudioObjectSystemObject), as: AudioObjectID.self) else { return }
        if output != device {
            if let listener {
                for address in [Self.level, Self.mute] {
                    var address = address
                    AudioObjectRemovePropertyListenerBlock(device, &address, .main, listener)
                }
            }
            device = output
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            for address in [Self.level, Self.mute] {
                var address = address
                AudioObjectAddPropertyListenerBlock(device, &address, .main, listener)
            }
            self.listener = listener
        }
        refresh()
    }

    private static func read<Value>(_ address: AudioObjectPropertyAddress, of object: AudioObjectID, as type: Value.Type) -> Value? {
        guard object != kAudioObjectUnknown else { return nil }
        var address = address
        var size = UInt32(MemoryLayout<Value>.size)
        let value = UnsafeMutablePointer<Value>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }
}
