//
//  SystemVolume.swift
//  Wand
//
//  CoreAudio volume read/write + a listener-based revert guard that reverses
//  AVRCP-origin volume changes during a short window after a remote volume HID press.
//

import AudioToolbox
import CoreAudio
import Foundation

enum SystemVolume {
    static func get() -> Float? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        var volume: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &volume)
        return status == noErr ? volume : nil
    }

    static func set(_ volume: Float) {
        guard let deviceID = defaultOutputDeviceID() else { return }
        var v = max(0, min(1, volume))
        let size = UInt32(MemoryLayout<Float>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &v)
    }

    static func isMuted() -> Bool? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &muted)
        return status == noErr ? muted != 0 : nil
    }

    static func setMuted(_ muted: Bool) {
        guard let deviceID = defaultOutputDeviceID() else { return }
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &value)
    }

    static func defaultOutputDeviceID() -> AudioObjectID? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return (status == noErr && id != 0) ? id : nil
    }

    /// Select an output device whose CoreAudio name matches the connected Bluetooth device.
    /// AirPods audio endpoints may appear a few seconds after the baseband connection, so the
    /// caller retries this method until the endpoint is published.
    static func setDefaultOutputDevice(named bluetoothName: String) -> Bool {
        guard let deviceID = outputDeviceID(named: bluetoothName) else { return false }
        return setDefaultOutputDevice(deviceID)
    }

    /// Route audio back to a real built-in output before disconnecting AirPods. Leaving the
    /// Bluetooth endpoint selected lets macOS reconnect it as soon as any app plays a sound.
    static func setDefaultBuiltInOutputDevice() -> Bool {
        guard let deviceID = allAudioDeviceIDs().first(where: { deviceID in
            hasOutputStreams(deviceID) && transportType(deviceID) == kAudioDeviceTransportTypeBuiltIn
        }) else { return false }
        return setDefaultOutputDevice(deviceID)
    }

    static func hasBluetoothAirPodsOutput() -> Bool {
        allAudioDeviceIDs().contains { id in
            guard hasOutputStreams(id),
                  transportType(id) == kAudioDeviceTransportTypeBluetooth,
                  let name = deviceName(id) else { return false }
            let normalizedName = normalizedDeviceName(name)
            return normalizedName.contains("airpods") || normalizedName.contains("air pods")
        }
    }

    private static func setDefaultOutputDevice(_ deviceID: AudioObjectID) -> Bool {
        var id = deviceID
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        var outputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let outputStatus = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &outputAddress, 0, nil, size, &id
        )

        // Keep alert/system sounds on the same AirPods when macOS exposes this writable key.
        var systemAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &systemAddress, 0, nil, size, &id
        )
        return outputStatus == noErr
    }

    private static func outputDeviceID(named targetName: String) -> AudioObjectID? {
        let devices = allAudioDeviceIDs().filter(hasOutputStreams)
        let normalizedTarget = normalizedDeviceName(targetName)
        if let exactMatch = devices.first(where: { id in
            guard let name = deviceName(id) else { return false }
            let normalizedName = normalizedDeviceName(name)
            return normalizedName == normalizedTarget ||
                normalizedName.contains(normalizedTarget) ||
                normalizedTarget.contains(normalizedName)
        }) {
            return exactMatch
        }

        // The Bluetooth service and CoreAudio endpoint frequently use different AirPods
        // names (for example "AirPods 4 (ANC)" versus "Ray‘s AirPods 4"). Only connected
        // audio endpoints appear in this list, so falling back to a Bluetooth AirPods output
        // is both more reliable and still avoids selecting unrelated Bluetooth speakers.
        guard normalizedTarget.contains("airpods") || normalizedTarget.contains("air pods") else {
            return nil
        }
        return devices.first { id in
            guard transportType(id) == kAudioDeviceTransportTypeBluetooth,
                  let name = deviceName(id) else { return false }
            let normalizedName = normalizedDeviceName(name)
            return normalizedName.contains("airpods") || normalizedName.contains("air pods")
        }
    }

    private static func allAudioDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var devices = Array(repeating: AudioObjectID(0), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &devices
        ) == noErr else { return [] }
        return devices
    }

    private static func hasOutputStreams(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr &&
            size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private static func transportType(_ deviceID: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr
            ? value : nil
    }

    private static func deviceName(_ deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? name as String : nil
    }

    private static func normalizedDeviceName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: " ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Reverts AVRCP-origin volume changes caused by the Siri Remote's volume buttons.
///
/// Design: a CoreAudio listener continuously tracks system volume. It maintains a
/// `baselineVolume` that lags real volume by `settleDelay` — any observed change stays
/// provisional for that interval. If a remote volume HID press (`armFromRemoteButton()`)
/// arrives during the settle window, we retroactively revert to the pre-change baseline.
/// During a 500ms guard window after a press, further changes are reverted immediately.
///
/// Why lagged baseline: BT AVRCP can beat the HID callback to main. A plain snapshot-on-
/// press approach captures the post-change volume and has nothing to revert to. By holding
/// changes provisional for ~150ms, the HID press still has time to claim the change.
///
/// Keyboard/other-origin volume changes (outside a guard window with no close HID press)
/// pass through normally — after `settleDelay` they become the new baseline.
final class VolumeRevertGuard {
    static let shared = VolumeRevertGuard()

    private var baselineVolume: Float?
    private var guardUntil: Date = .distantPast
    private let guardWindow: TimeInterval = 0.5
    private let settleDelay: TimeInterval = 0.15
    private var pendingSettle: DispatchWorkItem?
    private var listenerInstalled = false
    private var listenerDeviceID: AudioObjectID = 0

    /// Install the CoreAudio listener and capture the starting baseline at app launch,
    /// so the first remote volume press has something to revert to.
    func prewarm() {
        ensureListener()
        if baselineVolume == nil {
            baselineVolume = SystemVolume.get()
        }
        rmDebug("🔊 VolumeRevertGuard prewarm: listener=\(listenerInstalled) baseline=\(baselineVolume.map { String(format: "%.3f", $0) } ?? "nil")")
    }

    /// Called on every volume HID press from the remote. Opens the guard window and, if a
    /// volume change landed in the last `settleDelay` ms, reverts it retroactively — this
    /// handles the common case where AVRCP beats HID to the main thread.
    func armFromRemoteButton() {
        // Defensive: covers the default output device appearing/changing after launch,
        // when prewarm() found nothing to listen to.
        ensureListener()
        if baselineVolume == nil { baselineVolume = SystemVolume.get() }
        guardUntil = Date().addingTimeInterval(guardWindow)
        if pendingSettle != nil, let baselineValue = baselineVolume {
            pendingSettle?.cancel()
            pendingSettle = nil
            SystemVolume.set(baselineValue)
        }
    }

    private func ensureListener() {
        guard !listenerInstalled, let id = SystemVolume.defaultOutputDeviceID() else { return }
        listenerDeviceID = id
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main) { [weak self] _, _ in
            self?.onVolumeChanged()
        }
        if status == noErr {
            listenerInstalled = true
        }
    }

    private func onVolumeChanged() {
        guard let current = SystemVolume.get() else {
            rmDebug("🔊 listener fired but SystemVolume.get() returned nil")
            return
        }
        let baselineStr = baselineVolume.map { String(format: "%.3f", $0) } ?? "nil"
        let inWindow = Date() < guardUntil
        rmDebug("🔊 listener: current=\(String(format: "%.3f", current)) baseline=\(baselineStr) inGuard=\(inWindow)")

        // Our own revert write echoes back as a listener callback; noop when it matches.
        if let baseline = baselineVolume, abs(current - baseline) < 0.001 {
            rmDebug("🔊 listener: match baseline, noop")
            return
        }

        if inWindow, let baseline = baselineVolume {
            rmDebug("🔊 listener: reverting \(String(format: "%.3f", current)) → \(String(format: "%.3f", baseline))")
            SystemVolume.set(baseline)
            return
        }
        // Outside guard: defer committing this as the new baseline. If a remote HID press
        // arrives within settleDelay, it retroactively reverts instead.
        let captured = current
        pendingSettle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.baselineVolume = captured
            self?.pendingSettle = nil
            rmDebug("🔊 settle: baseline committed = \(String(format: "%.3f", captured))")
        }
        pendingSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: work)
    }
}
