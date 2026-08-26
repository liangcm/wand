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
    private var isButtonModeSelectPressed = false
    private let selectDragHoldInterval: TimeInterval = 0.25
    var onButtonModeSelectStateChanged: ((Bool) -> Void)?
    
    // Prevent double-processing with MediaKeyInterceptor
    static var lastProcessedButton: String?
    static var lastProcessedTime: UInt64 = 0
    private static var lastFilmlyPlayPauseDispatchAt: TimeInterval = 0

    static func claimFilmlyPlayPauseDispatch() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFilmlyPlayPauseDispatchAt > 0.08 else { return false }
        lastFilmlyPlayPauseDispatchAt = now
        return true
    }

    /// Last observed pressed/released state per button. The Siri Remote mirrors each logical
    /// button across multiple HID interfaces (6 seized here), so every physical press/release
    /// fires the callback N times. This collapses dup events to a single state transition.
    private var buttonState: [String: Bool] = [:]
    private var pendingSingleClicks: [String: DispatchWorkItem] = [:]
    private let doubleClickInterval: TimeInterval = 0.256
    private var pendingDouyinSelectClick: DispatchWorkItem?
    private let douyinSelectDoubleClickInterval: TimeInterval = 0.288
    private var tvPressActive = false
    private var tvLongPressTriggered = false
    private var tvLongPressWork: DispatchWorkItem?
    private let tvLongPressInterval: TimeInterval = 1
    private var missionControlOverlayActive = false

    private(set) var controlMode: RemoteControlMode
    private var isMacTVFrontmost = false
    private var powerPressActive = false
    private var powerSleepWork: DispatchWorkItem?
    private var muteLongPressWork: DispatchWorkItem?
    private var muteLongPressTriggered = false
    private var muteStateBeforePress: Bool?
    private var muteSingleClickWork: DispatchWorkItem?
    private var muteSecondPress = false
    private var mutePressActive = false
    private let muteLongPressInterval: TimeInterval = 1
    var onControlModeChanged: ((RemoteControlMode) -> Void)?
    var onPowerButtonPressed: (() -> Void)?

    // Return/Menu remains a normal short-press mapping, but holding it quits the frontmost app.
    private var backLongPressWork: DispatchWorkItem?
    private var backLongPressTriggered = false
    private let backLongPressInterval: TimeInterval = 1
    
    init(cursorController: CursorController, menuBarManager: MenuBarManager) {
        self.cursorController = cursorController
        self.menuBarManager = menuBarManager
        controlMode = RemoteControlMode(rawValue: UserDefaults.standard.string(forKey: "remoteControlMode") ?? "") ?? .trackpad
    }

    /// Mac TV owns the remote mode while it is the frontmost app: its launcher uses button
    /// navigation, while every other app receives Wand's pointer/trackpad behavior.
    func setMacTVFrontmost(_ frontmost: Bool) {
        if missionControlOverlayActive {
            // Mission Control does not itself replace Mac TV as the frontmost application.
            // A later real activation/resignation means the overlay has been dismissed.
            missionControlOverlayActive = false
            rmDebug("🌐 Mission Control overlay ended — TV button restored")
        }
        isMacTVFrontmost = frontmost
        applyControlMode(frontmost ? .buttons : .trackpad, reason: "Mac TV frontmost=\(frontmost)")
    }

    /// Mission Control is a Dock-owned system overlay and does not replace Mac TV as the
    /// frontmost application. Explicitly release button mode so the touch surface can move
    /// and click the pointer while the overlay is visible.
    func prepareForMissionControl() {
        if missionControlOverlayActive {
            missionControlOverlayActive = false
            let macTVIsFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.ray.livingroommode"
            applyControlMode(macTVIsFrontmost ? .buttons : .trackpad,
                             reason: "Mission Control toggled closed")
            rmDebug("🌐 Mission Control toggled closed — TV button restored")
            return
        }
        missionControlOverlayActive = true
        cancelTVLongPress()
        tvPressActive = false
        pendingSingleClicks.removeValue(forKey: "tv")?.cancel()
        applyControlMode(.trackpad, reason: "Mission Control opened over Mac TV")
    }

    /// A center press or light tap normally selects a Mission Control window and dismisses
    /// the overlay. Wait for that selection to settle, then restore TV-button handling even
    /// when the selected window is Mac TV and no workspace activation notification is sent.
    func missionControlPointerSelectionCompleted() {
        guard missionControlOverlayActive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.missionControlOverlayActive else { return }
            self.missionControlOverlayActive = false
            let macTVIsFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.ray.livingroommode"
            self.applyControlMode(macTVIsFrontmost ? .buttons : .trackpad,
                                  reason: "Mission Control pointer selection completed")
            rmDebug("🌐 Mission Control selection completed — TV button restored")
        }
    }

    private func applyControlMode(_ mode: RemoteControlMode, reason: String) {
        guard controlMode != mode else {
            rmDebug("🎛 \(reason) — already in \(mode.rawValue) mode")
            return
        }
        controlMode = mode
        if mode == .buttons {
            releaseSelectIfNeeded(reason: "switched to button mode")
        }
        UserDefaults.standard.set(mode.rawValue, forKey: "remoteControlMode")
        rmDebug("🎛 \(reason) → \(mode.rawValue) mode")
        onControlModeChanged?(mode)
    }

    deinit {
        powerSleepWork?.cancel()
        pendingDouyinSelectClick?.cancel()
        cancelTVLongPress()
        cancelMuteLongPress()
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
            if isButtonModeSelectPressed {
                isButtonModeSelectPressed = false
                onButtonModeSelectStateChanged?(false)
            }
            powerSleepWork?.cancel()
            powerSleepWork = nil
            powerPressActive = false
            pendingDouyinSelectClick?.cancel()
            pendingDouyinSelectClick = nil
            cancelTVLongPress()
            tvPressActive = false
            cancelMuteLongPress()
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
        if isPressed && (buttonName == "volumeUp" || buttonName == "volumeDown"),
           menuBarManager?.getMapping(for: buttonName) != .systemVolumeUp,
           menuBarManager?.getMapping(for: buttonName) != .systemVolumeDown {
            VolumeRevertGuard.shared.armFromRemoteButton()
        }

        // Power is reserved for the fixed mode switch and never runs a user mapping.
        // Handle it before the first-press guard so a deliberate first short press still works.
        if buttonName == "power" {
            handlePowerButton(pressed: isPressed)
            return
        }

        if buttonName == "mute" {
            handleMuteButton(pressed: isPressed)
            return
        }

        if buttonName == "tv" {
            handleTVButton(pressed: isPressed)
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
        let action = resolvedAction(for: buttonName)
        if pressed, buttonName == "playPause", action == .space,
           !Self.claimFilmlyPlayPauseDispatch() {
            return
        }
        if pressed && !action.isNativeMediaAction {
            RemoteInputHandler.lastProcessedButton = buttonName
            RemoteInputHandler.lastProcessedTime = mach_absolute_time()
        }
        if pressed {
            print("🔘 Button pressed: \(buttonName) → \(action.rawValue)")
        }
        executeAction(action, button: buttonName, pressed: pressed)
    }

    private func resolvedAction(for buttonName: String) -> RemoteAction {
        if buttonName == "playPause",
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.netease.filmlymac" {
            return .space
        }
        return menuBarManager?.getMapping(for: buttonName) ?? .none
    }
    
    private func handleSelectButton(pressed: Bool) {
        // The press can open another app immediately, which switches Wand to trackpad mode
        // before this same physical button is released. Keep ownership of that release here
        // so it cannot fall through as a click in the newly-frontmost app.
        if isButtonModeSelectPressed {
            if !pressed {
                isButtonModeSelectPressed = false
                onButtonModeSelectStateChanged?(false)
                rmDebug("⌨️ Select released after button-mode activation → suppress pointer click")
            }
            return
        }

        if controlMode == .buttons {
            if pressed {
                isButtonModeSelectPressed = true
                onButtonModeSelectStateChanged?(true)
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
                handleSelectShortPress()
            }
            selectBecameDrag = false
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.cursorController.isClickActive = false
            }
        }
    }

    private func handleSelectShortPress() {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.bytedance.douyin.desktop" else {
            rmDebug("🖱 Select short press → clean click")
            cursorController.performClick()
            missionControlPointerSelectionCompleted()
            return
        }

        if let pending = pendingDouyinSelectClick {
            pending.cancel()
            pendingDouyinSelectClick = nil
            rmDebug("🖱 Douyin center double press detected")
            cursorController.performDouyinSessionClick()
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDouyinSelectClick = nil
            rmDebug("🖱 Douyin center single press → normal click")
            self.cursorController.performClick()
        }
        pendingDouyinSelectClick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + douyinSelectDoubleClickInterval,
                                      execute: work)
    }

    private func handlePowerButton(pressed: Bool) {
        if pressed {
            guard !powerPressActive else { return }
            powerPressActive = true
            isFirstPressAfterConnection = false
            onPowerButtonPressed?()
            rmDebug("⏻ Power pressed — waiting for release before sleep")
            return
        }

        guard powerPressActive else { return }
        powerPressActive = false
        onPowerButtonPressed?()
        powerSleepWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.rmRequestSystemSleepAfterPowerRelease()
        }
        powerSleepWork = work
        // Sleeping on key-down lets the still-held remote wake the Mac immediately; the
        // subsequent release then opens macOS's shutdown panel. Wait until both HID and NX
        // release events have drained before asking the system to sleep.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func handleTVButton(pressed: Bool) {
        guard !missionControlOverlayActive else {
            rmDebug("📺 TV \(pressed ? "press" : "release") ignored while Mission Control is open")
            return
        }
        if pressed {
            guard !tvPressActive else { return }
            tvPressActive = true
            tvLongPressTriggered = false
            tvLongPressWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.tvPressActive else { return }
                self.tvLongPressTriggered = true
                self.pendingSingleClicks.removeValue(forKey: "tv")?.cancel()
                self.menuBarManager?.execute(.ctrlGrave, storageKey: "long:tv")
                rmDebug("📺 TV held for 1.00s — Ctrl+·")
            }
            tvLongPressWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + tvLongPressInterval, execute: work)
            return
        }

        guard tvPressActive else { return }
        tvPressActive = false
        tvLongPressWork?.cancel()
        tvLongPressWork = nil
        if tvLongPressTriggered {
            tvLongPressTriggered = false
            return
        }
        executeAction(resolvedAction(for: "tv"), button: "tv", pressed: true)
    }

    private func cancelTVLongPress() {
        tvLongPressWork?.cancel()
        tvLongPressWork = nil
        tvLongPressTriggered = false
    }

    private func rmRequestSystemSleepAfterPowerRelease() {
        powerSleepWork = nil
        rmDebug("⏻ Power released — requesting system sleep")
        requestSystemSleep()
    }

    private func requestSystemSleep() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["sleepnow"]
        do {
            try process.run()
        } catch {
            rmDebug("⚠️ Unable to request system sleep: \(error.localizedDescription)")
        }
    }

    private func handleMuteButton(pressed: Bool) {
        // Away from login/lock screen the mute button is a plain native media key. Do not
        // introduce double-click or long-press timing, and let the mirrored NX event pass.
        guard isLoginOrLockScreenActive() else {
            cancelMuteLongPress()
            rmDebug("🔇 Mute \(pressed ? "press" : "release") on desktop — native system mute")
            return
        }

        // On login/lock screen: one press sends Enter, two presses type "jade". There is no
        // long-press action in this context.
        if pressed {
            mutePressActive = true
            if let pendingSingle = muteSingleClickWork {
                pendingSingle.cancel()
                muteSingleClickWork = nil
                muteSecondPress = true
            } else {
                muteSecondPress = false
            }
            return
        }

        mutePressActive = false

        if muteSecondPress {
            muteSecondPress = false
            menuBarManager?.typeLiteral("jade")
            rmDebug("🔇 Mute double press on login/lock screen — typed literal text: jade")
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.muteSingleClickWork = nil
            self.menuBarManager?.execute(.enter, storageKey: "lock:mute")
            rmDebug("🔇 Mute single press on login/lock screen — Enter")
        }
        muteSingleClickWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleClickInterval, execute: work)
    }

    private func cancelMuteLongPress() {
        muteLongPressWork?.cancel()
        muteLongPressWork = nil
        muteSingleClickWork?.cancel()
        muteSingleClickWork = nil
        muteLongPressTriggered = false
        muteSecondPress = false
        mutePressActive = false
        muteStateBeforePress = nil
    }

    var shouldConsumeMuteMediaKey: Bool {
        isLoginOrLockScreenActive()
    }

    private func isLoginOrLockScreenActive() -> Bool {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow" {
            return true
        }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private func restoreMuteStateBeforeGesture() {
        if let originalMuteState = muteStateBeforePress {
            SystemVolume.setMuted(originalMuteState)
        }
    }

    private func performSingleMuteAction() {
        guard let current = SystemVolume.isMuted() else { return }
        if let originalMuteState = muteStateBeforePress {
            // If a raw Bluetooth mute event slipped through before the HID press was observed,
            // it already toggled the state. Otherwise apply the single toggle now.
            if current == originalMuteState {
                SystemVolume.setMuted(!originalMuteState)
            }
        } else {
            SystemVolume.setMuted(!current)
        }
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
        if missionControlOverlayActive {
            // Escape dismisses Mission Control without necessarily producing an application
            // activation notification because Mac TV can remain frontmost underneath it.
            missionControlOverlayActive = false
            let macTVIsFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.ray.livingroommode"
            setMacTVFrontmost(macTVIsFrontmost)
            rmDebug("🌐 Mission Control dismissed by Return/Esc — TV button restored")
        }
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
