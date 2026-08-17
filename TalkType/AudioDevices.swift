import CoreAudio
import Foundation

/// Enumerates audio input devices and resolves a saved choice back to a live device.
///
/// Devices are remembered by UID rather than `AudioDeviceID`: the numeric ID is assigned
/// at connect time, so AirPods get a different one every time they reconnect, while the
/// UID is stable.
enum AudioDevices {

    struct Device: Equatable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let isBluetooth: Bool
    }

    /// Every device that can currently record, in the order CoreAudio reports them.
    static func inputDevices() -> [Device] {
        allDeviceIDs()
            .filter { hasInputChannels($0) }
            .compactMap { id in
                guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                      let name = stringProperty(id, kAudioObjectPropertyName)
                else { return nil }
                return Device(id: id, uid: uid, name: name, isBluetooth: isBluetooth(id))
            }
    }

    /// The device the system would pick on its own.
    static func systemDefaultInput() -> Device? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0
        else { return nil }
        return describe(deviceID)
    }

    /// The machine's own microphone. It is the one input that is always present and
    /// always startable, which makes it the last resort when the chosen device refuses
    /// to hand over audio (a USB webcam mic whose driver will not start, for instance).
    static func builtInInput() -> Device? {
        inputDevices().first { transportType($0.id) == kAudioDeviceTransportTypeBuiltIn }
    }

    /// An input other than `device` that is worth trying when `device` will not start.
    /// The built-in microphone first, then anything else still connected.
    static func alternativeInput(to device: Device?) -> Device? {
        let others = inputDevices().filter { $0.uid != device?.uid }
        return others.first { transportType($0.id) == kAudioDeviceTransportTypeBuiltIn } ?? others.first
    }

    private static func describe(_ deviceID: AudioDeviceID) -> Device? {
        guard let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID),
              let name = stringProperty(deviceID, kAudioObjectPropertyName)
        else { return nil }
        return Device(id: deviceID, uid: uid, name: name, isBluetooth: isBluetooth(deviceID))
    }

    /// The input to record from when the user has not pinned one. Follows the system
    /// default, whatever it is — including a Bluetooth headset. (Recording through a
    /// Bluetooth mic makes macOS switch the link into headset mode, which drops the
    /// output to 24 kHz mono for the duration; that is the price of "system default".)
    /// An explicit pick always wins; this only shapes Automatic.
    static func automaticInput() -> Device? {
        systemDefaultInput()
    }

    /// Resolve a saved UID. Returns nil when the preference is "follow the system", or
    /// when the remembered device is not plugged in — in both cases the caller should
    /// let CoreAudio choose rather than fail.
    static func device(forUID uid: String?) -> Device? {
        guard let uid = uid, !uid.isEmpty else { return nil }
        return inputDevices().first { $0.uid == uid }
    }

    // MARK: - CoreAudio plumbing

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else { return false }

        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    /// Whether the device is a Bluetooth headset or earbuds. The transport type is the
    /// durable signal — the name ("AirPods Pro") is not.
    private static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        switch transportType(id) {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return true
        default:
            return false
        }
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return 0
        }
        return value
    }

    /// The device's nominal input sample rate (e.g. 24000 for a Bluetooth headset in
    /// HFP mode, 48000 for the built-in array). Used to tell when the node format has
    /// actually settled on the new device after a switch.
    static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }
}
