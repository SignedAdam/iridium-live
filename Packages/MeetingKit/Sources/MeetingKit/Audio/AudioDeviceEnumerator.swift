import Foundation
import CoreAudio

public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let deviceID: AudioDeviceID
    public let uid: String
    public let name: String
    public var id: String { uid }
}

enum AudioDeviceEnumerator {
    static func inputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &ids) == noErr else { return [] }

        var result: [AudioInputDevice] = []
        for id in ids where hasInputChannels(id) {
            guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { continue }
            result.append(AudioInputDevice(deviceID: id, uid: uid, name: name))
        }
        return result
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return nil }
        return deviceID
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputDevices().first { $0.uid == uid }?.deviceID
    }

    static func name(forUID uid: String) -> String? {
        inputDevices().first { $0.uid == uid }?.name
    }

    static func observeDeviceChanges(_ handler: @escaping () -> Void) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
            handler()
        }
    }

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let ablPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                      alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ablPtr.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, ablPtr) == noErr else { return false }
        let abl = UnsafeMutableAudioBufferListPointer(ablPtr.assumingMemoryBound(to: AudioBufferList.self))
        var channels = 0
        for buffer in abl { channels += Int(buffer.mNumberChannels) }
        return channels > 0
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfString: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfString) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let cfString else { return nil }
        return cfString as String
    }
}
