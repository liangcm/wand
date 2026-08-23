//
//  RemoteInputHandler.swift
//  Wand
//
//  Processes HID input events from Siri Remote
//

import IOKit
import IOKit.hid
import Foundation
import Carbon.HIToolbox
import AppKit

/// The center click has two fixed, purpose-built meanings. This sits outside
/// configurable button mappings so the power key can switch it reliably.
enum RemoteControlMode: String {
    case trackpad
    case buttons
}

class RemoteInputHandler {
    private let cursorController: CursorController
    private weak var menuBarManager: MenuBarManager?
    private var devices: [IOHIDDevice] = []

    /// Serial queue to stagger HID device seizes. Seizing multiple interfaces of the
    /// same Bluetooth peripheral in rapid succession can crash the BT HID stack.
    private let seizeQueue = DispatchQueue(label: "com.wand.seize")
    /// Devices waiting to be seized, protected by seizeQueue (serial).
    private var pendingDevices: [IOHIDDevice] = []
    private var seizeTimerActive = false
    /// Bumped on each disconnect (on seizeQueue). Delayed seizes capture it at dispatch and
    /// abort if it changed — a disconnect mid-delay must not resurrect the interface.
    private var connectionGeneration = 0

    /// Called on any button activity; use to trigger trackpad re-scan after remote wake.
    var onButtonActivity: (() -> Void)?
    
    // First press after connection: do not perform action (sound already played at connect).
    private var isFirstPressAfterConnection = false
    
    // Click/drag state
    private var isSelectPressed = false
    private var selectHoldWork: DispatchWorkItem?
    private var selectBecameDrag = false
    private let selectDragHoldInterval: TimeInterval = 0.25
    
    // Prevent double-processing with MediaKeyInterceptor
    static var lastProcessedButton: String?
    static var lastProcessedTime: UInt64 = 0

    /// Last observed pressed/released state per button. The Siri Remote mirrors each logical
    /// button across multiple HID interfaces (6 seized here), so every physical press/release
    /// fires the callback N times. This collapses dup events to a single state transition.
    private var buttonState: [String: Bool] = [:]
    private var pendingSingleClicks: [String: DispatchWorkItem] = [:]
    private let doubleClickInterval: TimeInterval = 0.32

    private(set) var controlMode: RemoteControlMode
    private var powerPressStartedAt: Date?
    private let powerShortPressLimit: TimeInterval = 0.65
    var onControlModeChanged: ((RemoteControlMode) -> Void)?

    // Return/Menu remains a normal short-press mapping, but holding it quits the frontmost app.
    private var backLongPressWork: DispatchWorkItem?
    private var backLongPressTriggered = false
    private let backLongPressInterval: TimeInterval = 1
    
    init(cursorController: CursorController, menuBarManager: MenuBarManager) {
        self.cursorController = cursorController
        self.menuBarManager = menuBarManager
        controlMode = RemoteControlMode(rawValue: UserDefaults.standard.string(forKey: "remoteControlMode") ?? "") ?? .trackpad
    }

    deinit {
        cancelBackLongPress()
        releaseSelectIfNeeded(reason: "handler deinit")
    }
    
    func setRemoteDevice(_ device: IOHIDDevice?) {
        guard let device = device else {
            // Cancel pending seizes and drain queue. Bumping the generation also invalidates
            // any seize already dispatched into its 150ms delay — it re-checks on wake.
            seizeQueue.async { [weak self] in
                guard let self = self else { return }
                self.connectionGeneration += 1
                self.pendingDevices.removeAll()
                self.seizeTimerActive = false
            }
            releaseSelectIfNeeded(reason: "device removed")
            cancelBackLongPress()
            buttonState.removeAll()
            // A single click parked awaiting double-click resolution must not fire after
            // the remote is gone.
            for (_, work) in pendingSingleClicks { work.cancel() }
            pendingSingleClicks.removeAll()
            for d in devices {
                IOHIDDeviceRegisterInputValueCallback(d, nil, nil)
                IOHIDDeviceUnscheduleFromRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
                IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            devices.removeAll()
            isFirstPressAfterConnection = false
            return
        }

        guard !devices.contains(where: { $0 == device }) else { return }

        // Stagger seizing: multiple HID interfaces from the same Bluetooth peripheral
        // arrive in rapid succession. Seizing them all synchronously can overwhelm the
        // macOS Bluetooth HID stack and crash the controller. Queue each seize with a
        // 150ms gap so the stack has time to settle between each one.
        seizeQueue.async { [weak self] in
            guard let self = self else { return }
            self.pendingDevices.append(device)
            if !self.seizeTimerActive {
                self.seizeTimerActive = true
                self.drainNext()
            }
        }
    }

    /// Pick the next device from the pending queue and seize it with a 150ms delay.
    /// The captured generation invalidates the delayed seize if a disconnect happened while
    /// it was waiting — otherwise it would seize an interface the UI already considers gone.
    private func drainNext() {
        guard !pendingDevices.isEmpty else {
            seizeTimerActive = false
            return
        }
        let device = pendingDevices.removeFirst()
        let gen = connectionGeneration
        seizeQueue.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
            guard let self = self else { return }
            if self.connectionGeneration == gen {
                self.seizeDeviceNow(device)
            }
            self.drainNext()
        }
    }

    /// Actually perform the IOHIDDeviceOpen+seize (called from the seize queue).
    private func seizeDeviceNow(_ device: IOHIDDevice) {
        let vendor = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0

        // Seize device to prevent system from handling events
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))

        if openResult == kIOReturnSuccess {
            rmDebug(String(format: "🔒 SEIZED HID device (vendor=0x%X product=0x%X)",
                          vendor, product))
            DispatchQueue.main.async { [weak self] in
                self?.attachSeizedDevice(device)
            }
        } else {
            rmDebug(String(format: "⚠️ FAILED to seize HID device (IOReturn=0x%X) — opening unseized", openResult))
            if IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess {
                DispatchQueue.main.async { [weak self] in
                    self?.attachSeizedDevice(device)
                }
            }
        }
    }

    /// Register callbacks for an opened interface (main thread). The first-press guard is armed
    /// only for the FIRST interface of a connection — the remote mirrors buttons across ~6
    /// interfaces seized 150ms apart, and re-arming on each one would swallow a real keypress
    /// made up to ~1s after connect.
    private func attachSeizedDevice(_ device: IOHIDDevice) {
        IOHIDDeviceRegisterInputValueCallback(device, inputValueCallback, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let isFirstInterface = devices.isEmpty
        devices.append(device)
        if isFirstInterface { isFirstPressAfterConnection = true }
    }

    private func releaseSelectIfNeeded(reason: String) {
        selectHoldWork?.cancel()
        selectHoldWork = nil
        guard isSelectPressed else { return }
        rmDebug("🖱 Select cancel fallback (\(reason))")
        isSelectPressed = false
        cursorController.isDragging = false
        cursorController.isClickActive = false
        if selectBecameDrag {
            cursorController.mouseUp()
        }
        selectBecameDrag = false
    }
    
    func handleInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)

        let identified = identifyButton(page: usagePage, usage: usage)
        rmDebug(String(format: "🎮 HID event: page=0x%X usage=0x%X value=%d → %@",
                       usagePage, usage, intValue, identified ?? "<unmapped>"))
        guard let buttonName = identified else { return }

        onButtonActivity?()

        // Collapse mirrored-interface duplicates: only proceed on a real state transition.
        let isPressed = (intValue == 1)
        if buttonState[buttonName] == isPressed {
            return
        }
        buttonState[buttonName] = isPressed

        // Volume keys on the Siri Remote also travel over BT AVRCP absolute-volume, which
        // coreaudiod honors below cghidEventTap. Arm the revert guard on every press so the
        // CoreAudio listener snaps the level back to the pre-press value.
        if isPressed && (buttonName == "volumeUp" || buttonName == "volumeDown") {
            VolumeRevertGuard.shared.armFromRemoteButton()
        }

        // Power is reserved for the fixed mode switch and never runs a user mapping.
        // Handle it before the first-press guard so a deliberate first short press still works.
        if buttonName == "power" {
            handlePowerButton(pressed: isPressed)
            return
        }

        // First key-down after connection: skip so the connect handshake doesn't fire an action.
        if intValue == 1 && isFirstPressAfterConnection {
            isFirstPressAfterConnection = false
            return
        }

        // Return/Menu needs press duration, so its normal short action fires on release. This
        // branch sits after the first-press guard by design.
        if buttonName == "menu" || buttonName == "back" {
            handleBackButton(button: buttonName, pressed: isPressed)
            return
        }

        // Select is the trackpad click — handled separately for click/drag semantics.
        if buttonName == "select" {
            handleSelectButton(pressed: intValue == 1)
            return
        }

        let pressed = (intValue == 1)

        // Debounce only on press — actions fire on press, release does nothing.
        if pressed {
            RemoteInputHandler.lastProcessedButton = buttonName
            RemoteInputHandler.lastProcessedTime = mach_absolute_time()
        }

        let action = menuBarManager?.getMapping(for: buttonName) ?? RemoteAction.none
        if pressed {
            print("🔘 Button pressed: \(buttonName) → \(action.rawValue)")
        }
        executeAction(action, button: buttonName, pressed: pressed)
    }
    
    private func handleSelectButton(pressed: Bool) {
        if controlMode == .buttons {
            if pressed {
                rmDebug("⌨️ Select pressed in button mode → Enter")
                menuBarManager?.execute(.enter, storageKey: "mode-select")
            }
            return
        }

        if pressed && !isSelectPressed {
            isSelectPressed = true
            cursorController.isClickActive = true
            selectBecameDrag = false
            selectHoldWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isSelectPressed, self.controlMode == .trackpad else { return }
                self.selectBecameDrag = true
                self.cursorController.isDragging = true
                self.cursorController.mouseDown()
                rmDebug("🖱 Select held → begin drag")
            }
            selectHoldWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + selectDragHoldInterval,
                                          execute: work)
            rmDebug("🖱 Select pressed → waiting for click/drag decision")
        } else if !pressed && isSelectPressed {
            selectHoldWork?.cancel()
            selectHoldWork = nil
            isSelectPressed = false
            cursorController.isDragging = false
            if selectBecameDrag {
                rmDebug("🖱 Select released → end drag")
                cursorController.mouseUp()
            } else {
                rmDebug("🖱 Select short press → clean click")
                cursorController.performClick()
            }
            selectBecameDrag = false
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.cursorController.isClickActive = false
            }
        }
    }

    private func handlePowerButton(pressed: Bool) {
        if pressed {
            isFirstPressAfterConnection = false
            powerPressStartedAt = Date()
            return
        }

        guard let startedAt = powerPressStartedAt else { return }
        powerPressStartedAt = nil
        let duration = Date().timeIntervalSince(startedAt)
        guard duration <= powerShortPressLimit else {
            rmDebug(String(format: "⏻ Power held for %.2fs — mode unchanged", duration))
            return
        }

        controlMode = controlMode == .trackpad ? .buttons : .trackpad
        if controlMode == .buttons {
            releaseSelectIfNeeded(reason: "switched to button mode")
        }
        UserDefaults.standard.set(controlMode.rawValue, forKey: "remoteControlMode")
        rmDebug("⏻ Power short press → \(controlMode.rawValue) mode")
        onControlModeChanged?(controlMode)
    }

    private func handleBackButton(button: String, pressed: Bool) {
        if pressed {
            cancelBackLongPress()
            backLongPressTriggered = false
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.backLongPressTriggered = true
                self.menuBarManager?.beginQuitFrontmostApplicationHold()
                rmDebug("↩︎ Return held → Cmd+Q keyDown")
            }
            backLongPressWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + backLongPressInterval,
                                          execute: work)
            return
        }

        backLongPressWork?.cancel()
        backLongPressWork = nil
        guard !backLongPressTriggered else {
            menuBarManager?.endQuitFrontmostApplicationHold()
            rmDebug("↩︎ Return released → Cmd+Q keyUp")
            backLongPressTriggered = false
            return
        }

        let action = menuBarManager?.getMapping(for: button) ?? .none
        executeAction(action, button: button, pressed: true)
    }

    private func cancelBackLongPress() {
        backLongPressWork?.cancel()
        backLongPressWork = nil
        if backLongPressTriggered {
            menuBarManager?.endQuitFrontmostApplicationHold()
        }
        backLongPressTriggered = false
    }

    // MARK: - Button Identification
    
    private func identifyButton(page: UInt32, usage: UInt32) -> String? {
        switch (page, usage) {
        // Generic Desktop Page (0x01)
        case (0x01, 0x86): return "menu"          // System Menu Main
        case (0x01, 0x40): return "menu"          // Menu (alternative)
        
        // Consumer Page (0x0C)  
        case (0x0C, 0x04): return "siri"          // Siri button (actual)
        case (0x0C, 0x60): return "tv"            // TV button (actual)
        case (0x0C, 0x80): return "select"        // Selection
        case (0x0C, 0x41): return "select"        // Menu Select (alternative)
        case (0x0C, 0x42): return "dpadUp"        // Menu Up — 触控板上方向点击
        case (0x0C, 0x43): return "dpadDown"      // Menu Down — 下方向点击
        case (0x0C, 0x44): return "dpadLeft"      // Menu Left — 左方向点击
        case (0x0C, 0x45): return "dpadRight"     // Menu Right — 右方向点击
        case (0x0C, 0xCD): return "playPause"     // Play/Pause
        case (0x0C, 0xE9): return "volumeUp"      // Volume Increment
        case (0x0C, 0xEA): return "volumeDown"    // Volume Decrement
        case (0x0C, 0xB5): return "nextTrack"     // Scan Next Track
        case (0x0C, 0xB6): return "prevTrack"     // Scan Previous Track
        case (0x0C, 0x223): return "tv"           // AC Home (TV button alternative)
        case (0x0C, 0x224): return "back"         // AC Back
        case (0x0C, 0x40): return "menu"          // Menu
        case (0x0C, 0x30): return "power"         // Power
        case (0x0C, 0x20): return "mute"          // Mute (some remotes)
        case (0x0C, 0xE2): return "mute"          // HID Consumer Mute (silver Siri Remote)
        
        // Button Page (0x09)
        case (0x09, 0x01): return "select"        // Button 1
        
        // Apple Vendor Page (0xFF00) - Siri button
        case (0xFF00, 0x01): return "siri"        // Siri button
        case (0xFF00, 0x02): return "siri"        // Siri button (alternative)
        case (0xFF00, 0x03): return "siri"        // Siri button (alternative)
        case (0xFF00, _): return "siri"           // Any Apple vendor usage = likely Siri
        
        // Telephony Page (0x0B) - sometimes used for Siri
        case (0x0B, 0x21): return "siri"          // Flash
        case (0x0B, 0x2F): return "siri"          // Phone Mute
        
        default: return nil
        }
    }
    
    // MARK: - Action Execution
    
    private func executeAction(_ action: RemoteAction, button: String, pressed: Bool, bypassDouble: Bool = false) {
        if !bypassDouble, pressed,
           let manager = menuBarManager,
           manager.getDoubleClickMapping(for: button) != .none {
            if let pending = pendingSingleClicks.removeValue(forKey: button) {
                pending.cancel()
                let doubleAction = manager.getDoubleClickMapping(for: button)
                executeAction(doubleAction, button: "double:\(button)", pressed: true, bypassDouble: true)
                return
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingSingleClicks.removeValue(forKey: button)
                self.executeAction(action, button: button, pressed: true, bypassDouble: true)
            }
            pendingSingleClicks[button] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + doubleClickInterval, execute: work)
            return
        }
        // Every action is a single tap now, fired on press only.
        guard pressed else { return }
        // Click goes through the shared cursor state so it stays consistent with the trackpad path.
        if action == .leftClick {
            cursorController.performClick()
            return
        }
        // `button` is already the MappingTarget.storageKey ("siri", "double:siri"), which is
        // what execute needs to resolve the data-backed actions.
        menuBarManager?.execute(action, storageKey: button)
    }
}

// C callback
private func inputValueCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, value: IOHIDValue) {
    guard let context = context else { return }
    Unmanaged<RemoteInputHandler>.fromOpaque(context).takeUnretainedValue().handleInputValue(value)
}
