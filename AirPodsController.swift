//
//  AirPodsController.swift
//  Wand
//
//  Toggles the most recently used (or explicitly selected) paired AirPods and routes
//  system audio to it after connection. Uses macOS's built-in IOBluetooth/CoreAudio APIs.
//

import AppKit
import Foundation
import IOBluetooth

struct AirPodsDeviceSummary {
    let address: String
    let name: String
    let isConnected: Bool
    let isSelected: Bool
}

enum AirPodsFeedbackState: Equatable {
    case progress
    case success
    case failure
}

final class AirPodsController {
    private let selectedAddressKey = "selectedAirPodsAddress"
    private let operationQueue = DispatchQueue(label: "com.wand.airpods-toggle")
    private(set) var isBusy = false
    private var operationGeneration = 0

    var onStateChanged: (() -> Void)?
    var onFeedback: ((String, AirPodsFeedbackState) -> Void)?

    var menuTitle: String {
        guard let device = selectedDevice() else { return tr("airpods.notFound") }
        let state = device.isConnected() ? tr("airpods.connected") : tr("airpods.disconnected")
        return String(format: tr("airpods.toggle.named"), device.nameOrAddress ?? "AirPods", state)
    }

    func deviceSummaries() -> [AirPodsDeviceSummary] {
        let selectedAddress = resolvedSelectedAddress()
        return airPodsDevices().map { device in
            let address = device.addressString ?? ""
            return AirPodsDeviceSummary(
                address: address,
                name: device.nameOrAddress ?? "AirPods",
                isConnected: device.isConnected(),
                isSelected: address.caseInsensitiveCompare(selectedAddress ?? "") == .orderedSame
            )
        }
    }

    func select(address: String) {
        guard airPodsDevices().contains(where: {
            $0.addressString?.caseInsensitiveCompare(address) == .orderedSame
        }) else { return }
        UserDefaults.standard.set(address, forKey: selectedAddressKey)
        onStateChanged?()
    }

    func toggle() {
        guard let device = selectedDevice() else {
            feedback(tr("airpods.notFound"), state: .failure)
            return
        }

        let bluetoothConnected = device.isConnected()
        let name = device.nameOrAddress ?? "AirPods"
        if bluetoothConnected && SystemVolume.hasBluetoothAirPodsOutput() {
            feedback(String(format: tr("airpods.didConnect"), name), state: .success)
            return
        }

        guard !isBusy else {
            feedback(tr("airpods.busy"), state: .progress)
            return
        }

        if let address = device.addressString {
            UserDefaults.standard.set(address, forKey: selectedAddressKey)
        }
        operationGeneration += 1
        let generation = operationGeneration
        isBusy = true
        onStateChanged?()
        feedback(String(format: tr("airpods.connecting"), name), state: .progress)

        // Bluetooth may already be connected while its audio profile is still being
        // published. In that state, wait for CoreAudio instead of issuing another connect.
        if bluetoothConnected {
            waitForAudioOutput(
                device: device,
                fallbackName: name,
                attemptsRemaining: 24,
                generation: generation
            )
            return
        }

        operationQueue.async { [weak self] in
            guard let self else { return }
            let result = device.openConnection()
            DispatchQueue.main.async {
                guard generation == self.operationGeneration else { return }
                guard result == kIOReturnSuccess else {
                    self.finishOperation(
                        String(format: tr("airpods.connectFailed"), name, result),
                        generation: generation,
                        succeeded: false
                    )
                    return
                }
                self.waitForAudioOutput(
                    device: device,
                    fallbackName: name,
                    attemptsRemaining: 24,
                    generation: generation
                )
            }
        }
    }

    private func waitForAudioOutput(
        device: IOBluetoothDevice,
        fallbackName: String,
        attemptsRemaining: Int,
        generation: Int
    ) {
        guard generation == operationGeneration else { return }
        // AirPods often replace their cached Bluetooth name after connecting (for example
        // "Ray's AirPods 4" becomes "AirPods 4 (ANC)"). Re-read it on every poll so the
        // newly published CoreAudio endpoint can be matched immediately.
        let currentName = device.nameOrAddress ?? fallbackName
        if SystemVolume.setDefaultOutputDevice(named: currentName) {
            finishOperation(
                String(format: tr("airpods.didConnect"), currentName),
                generation: generation,
                succeeded: true
            )
            return
        }
        guard attemptsRemaining > 0 else {
            finishOperation(
                String(format: tr("airpods.connectedNoAudio"), currentName),
                generation: generation,
                succeeded: false
            )
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.waitForAudioOutput(
                device: device,
                fallbackName: fallbackName,
                attemptsRemaining: attemptsRemaining - 1,
                generation: generation
            )
        }
    }

    private func finishOperation(_ message: String, generation: Int, succeeded: Bool) {
        guard generation == operationGeneration else { return }
        isBusy = false
        feedback(message, state: succeeded ? .success : .failure)
        onStateChanged?()
    }

    private func feedback(_ message: String, state: AirPodsFeedbackState) {
        rmDebug("🎧 \(message)")
        onFeedback?(message, state)
    }

    private func selectedDevice() -> IOBluetoothDevice? {
        let devices = airPodsDevices()
        if let connected = devices.first(where: { $0.isConnected() }) {
            return connected
        }
        if let savedAddress = UserDefaults.standard.string(forKey: selectedAddressKey),
           let saved = devices.first(where: {
               $0.addressString?.caseInsensitiveCompare(savedAddress) == .orderedSame
           }) {
            return saved
        }
        return devices.first
    }

    private func resolvedSelectedAddress() -> String? {
        selectedDevice()?.addressString
    }

    /// `recentDevices` is already ordered newest-first. Append paired devices so a device
    /// still appears even when macOS has pruned it from the recent list, then de-duplicate.
    private func airPodsDevices() -> [IOBluetoothDevice] {
        let recent = (IOBluetoothDevice.recentDevices(0) as? [IOBluetoothDevice]) ?? []
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        var seen = Set<String>()
        return (recent + paired).filter { device in
            let name = (device.nameOrAddress ?? "").lowercased()
            guard name.contains("airpods") || name.contains("air pods") else { return false }
            let address = device.addressString ?? name
            return seen.insert(address.lowercased()).inserted
        }
    }
}
