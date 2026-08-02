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
    }

    /// Every device that can currently record, in the order CoreAudio reports them.
    static func inputDevices() -> [Device] {
        allDeviceIDs()
            .filter { hasInputChannels($0) }
            .compactMap { id in
                guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                      let name = stringProperty(id, kAudioObjectPropertyName)
                else { return nil }
                return Device(id: id, uid: uid, name: name)
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
              deviceID != 0,
              let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID),
              let name = stringProperty(deviceID, kAudioObjectPropertyName)
        else { return nil }
        return Device(id: deviceID, uid: uid, name: name)
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
