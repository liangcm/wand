//
//  SiriRemoteApp.swift
//  Wand
//
//  Menu bar application for controlling Mac with Siri Remote
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import IOKit.hid

class AppDelegate: NSObject, NSApplicationDelegate {
    private static let macTVModeNotification = Notification.Name("com.ray.mactv.wand.frontmost")
    
    private var statusItem: NSStatusItem!
    private var menuBarManager: MenuBarManager!
    private var remoteDetector: RemoteDetector?
    private var remoteInputHandler: RemoteInputHandler?
    private var mediaKeyInterceptor: MediaKeyInterceptor?
    private var touchHandler: TouchHandler?
    private var macTVModeObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var remoteRecoveryWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 Wand starting...")

        // Native media-button mappings need macOS's Remote Control Daemon. Restore it if an
        // older Wand run left it unloaded, then let MediaKeyInterceptor decide per mapping.
        RCDControl.restore()

        // Run as menu bar app (no dock icon)
        NSApp.setActivationPolicy(.accessory)
        
        // Create menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let statusItem = statusItem else {
            NSApp.terminate(nil)
            return
        }
        statusItem.isVisible = true
        
        // Initialize menu bar manager
        menuBarManager = MenuBarManager(statusItem: statusItem)
        if CommandLine.arguments.contains("--show-panel") {
            menuBarManager.showRemotePanel()
        }
        
        // Check accessibility permissions
        checkAccessibilityPermissions()
        
        // Initialize controllers
        let cursorController = CursorController()

        remoteInputHandler = RemoteInputHandler(
            cursorController: cursorController,
            menuBarManager: menuBarManager
        )
        remoteInputHandler?.onControlModeChanged = { [weak self] mode in
            self?.menuBarManager?.updateControlMode(mode)
            self?.touchHandler?.cancelCurrentGesture()
        }
        remoteInputHandler?.onButtonModeSelectStateChanged = { [weak self] active in
            self?.touchHandler?.setButtonModeSelectionActive(active)
        }
        macTVModeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.macTVModeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let frontmost = notification.userInfo?["frontmost"] as? Bool else { return }
            self?.remoteInputHandler?.setMacTVFrontmost(frontmost)
        }
        let macTVIsFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.ray.livingroommode"
        remoteInputHandler?.setMacTVFrontmost(macTVIsFrontmost)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(frontmostApplicationDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        if let mode = remoteInputHandler?.controlMode {
            menuBarManager.updateControlMode(mode)
        }
        // Cursor-nudge actions (方向环默认) run through the same controller as the trackpad.
        menuBarManager.cursorController = cursorController
        
        // Start touch handler for trackpad (before remote detection so we can wire the callback)
        touchHandler = TouchHandler(cursorController: cursorController)
        touchHandler?.scrollScale = menuBarManager.scrollSpeed.scale
        // Multi-finger (≥3) pinch-in opens the remote control panel. Detection accepts 3+
        // because the small trackpad reports a 4th contact unreliably.
        touchHandler?.onPinch = { [weak menuBarManager] in
            menuBarManager?.showRemotePanel()
        }
        // Tap-to-click respects the panel toggle, read live on each tap.
        touchHandler?.isTapEnabled = { [weak menuBarManager] in
            menuBarManager?.tapToClickEnabled ?? true
        }
        // Button mode blocks all direct trackpad gestures while keeping the device attached
        // so switching back to trackpad mode is immediate.
        touchHandler?.isPointerInputEnabled = { [weak self] in
            self?.remoteInputHandler?.controlMode == .trackpad
        }
        touchHandler?.start()
        remoteInputHandler?.onButtonActivity = { [weak self] in
            self?.touchHandler?.tryReconnectTrackpad()
        }
        
        // Start remote detection
        remoteDetector = RemoteDetector { [weak self] device in
            DispatchQueue.main.async {
                self?.remoteInputHandler?.setRemoteDevice(device)
                if let device,
                   let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int {
                    self?.menuBarManager.updateRemoteModel(AppleRemoteModel.identify(productID: productID))
                }
                self?.menuBarManager.updateConnectionStatus(connected: device != nil)
            }
        }
        remoteDetector?.startDetection()
        
        // Request Input Monitoring so media key tap works in both CLI and .app
        if #available(macOS 10.15, *) {
            if !CGPreflightListenEventAccess() {
                CGRequestListenEventAccess()
            }
        }
        
        // Start media key interceptor
        mediaKeyInterceptor = MediaKeyInterceptor()
        mediaKeyInterceptor?.onMediaKey = { [weak self] keyType in
            guard let self = self else { return false }
            return self.handleInterceptedMediaKey(keyType)
        }
        mediaKeyInterceptor?.start()
        remoteInputHandler?.onPowerButtonPressed = { [weak self] in
            // The Siri Remote also mirrors its power press as a native NX power event.
            // Re-enable the tap before that duplicate can reach macOS and open its shutdown UI.
            self?.mediaKeyInterceptor?.reenableTap()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.mediaKeyInterceptor?.reenableTap()
            self?.scheduleRemoteRecovery(after: 0.35, reason: "system wake")
        }

        // Install the CoreAudio volume listener + baseline now, so the first remote volume
        // press already has something to revert AVRCP's system-volume change to.
        VolumeRevertGuard.shared.prewarm()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        cleanup()
        return .terminateNow
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }
    
    private func cleanup() {
        remoteRecoveryWork?.cancel()
        remoteRecoveryWork = nil
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let macTVModeObserver {
            DistributedNotificationCenter.default().removeObserver(macTVModeObserver)
            self.macTVModeObserver = nil
        }
        touchHandler?.stop()
        remoteDetector?.stopDetection()
        mediaKeyInterceptor?.stop()
        RCDControl.restore()
    }

    private func scheduleRemoteRecovery(after delay: TimeInterval, reason: String) {
        remoteRecoveryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            rmDebug("🔄 Rebuilding remote HID connection after \(reason)")
            self.remoteDetector?.stopDetection()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                self.remoteDetector?.startDetection()
                self.touchHandler?.tryReconnectTrackpad()
                self.remoteRecoveryWork = nil
            }
        }
        remoteRecoveryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    @objc private func frontmostApplicationDidChange(_ notification: Notification) {
        let isMacTV = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.ray.livingroommode"
        remoteInputHandler?.setMacTVFrontmost(isMacTV)
    }
    
    // MARK: - Media Key Handling

    /// Convert mach_absolute_time() delta to seconds (machine ticks vary; use timebase).
    private static let machTimebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t(numer: 0, denom: 0)
        guard mach_timebase_info(&info) == 0 else { return (1, 1) }
        return (info.numer, info.denom)
    }()

    private static func machDeltaToSeconds(from start: UInt64) -> Double {
        guard start > 0 else { return .infinity }
        let now = mach_absolute_time()
        let delta = now >= start ? (now - start) : 0
        let nanos = delta * UInt64(Self.machTimebase.numer) / UInt64(Self.machTimebase.denom)
        return Double(nanos) / 1_000_000_000.0
    }
    
    private func handleInterceptedMediaKey(_ keyType: MediaKeyInterceptor.MediaKeyType) -> Bool {
        let buttonName: String
        switch keyType {
        case .playPause:  buttonName = "playPause"
        case .next:       buttonName = "nextTrack"
        case .previous:   buttonName = "prevTrack"
        case .volumeUp:   buttonName = "volumeUp"
        case .volumeDown: buttonName = "volumeDown"
        case .mute:       buttonName = "mute"
        case .power:      buttonName = "power"
        }

        // Power is fully owned by RemoteInputHandler: every press requests sleep. Never pass
        // the mirrored native power event to macOS, because
        // it opens the shutdown confirmation panel shown by the user.
        if keyType == .power {
            return true
        }

        // Wand owns the Siri Remote mute gesture until it can distinguish single, double,
        // and long press. Consuming the underlying media event prevents double-click Enter
        // and long-press text input from also toggling system mute.
        if keyType == .mute, remoteInputHandler?.shouldConsumeMuteMediaKey == true {
            return true
        }

        // 网易爆米花 uses Space for in-app playback. The HID path normally sends it first;
        // consume the mirrored system-media event so one remote press cannot fire twice.
        if keyType == .playPause,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.netease.filmlymac" {
            if RemoteInputHandler.claimFilmlyPlayPauseDispatch() {
                menuBarManager.execute(.space, storageKey: "filmly:playPause")
            }
            return true
        }

        let action = menuBarManager.getMapping(for: buttonName)
        let isMatchingNativeAction: Bool
        switch (keyType, action) {
        case (.playPause, .mediaPlayPause),
             (.volumeUp, .systemVolumeUp),
             (.volumeDown, .systemVolumeDown),
             (.mute, .systemMute):
            isMatchingNativeAction = true
        default:
            isMatchingNativeAction = false
        }
        if isMatchingNativeAction {
            return false
        }

        // Debounce: if the HID path just handled this button, don't double-fire.
        if RemoteInputHandler.lastProcessedButton == buttonName {
            let timeSinceLastProcess = Self.machDeltaToSeconds(from: RemoteInputHandler.lastProcessedTime)
            if timeSinceLastProcess < 0.2 {
                return true
            }
        }

        menuBarManager.execute(action, storageKey: buttonName)
        return true
    }
    
    // MARK: - Permissions
    
    private func checkAccessibilityPermissions() {
        // macOS will show its own prompt when needed
        // No need for redundant custom alert
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

/// Suspends `com.apple.rcd` (Remote Control Daemon) for the user's GUI launchd domain while
/// Wand is running. rcd is what reacts to Bluetooth AVRCP play signals by launching
/// Music.app — a channel that bypasses HID seize and the cghidEventTap entirely. `bootout`
/// only affects this login session; restored on clean exit, and on next login either way.
enum RCDControl {
    private static let plistPath = "/System/Library/LaunchAgents/com.apple.rcd.plist"
    private static var suspended = false

    static func suspend() {
        let domain = "gui/\(getuid())"
        let service = "\(domain)/com.apple.rcd"
        guard isLoaded(service: service) else {
            print("ℹ️ com.apple.rcd not loaded; skipping suspend")
            return
        }
        let (status, err) = run(["bootout", service])
        if status == 0 {
            suspended = true
            print("🔇 com.apple.rcd suspended (Music won't auto-launch from BT remote)")
        } else {
            print("⚠️ Could not suspend com.apple.rcd (launchctl exit=\(status)): \(err)")
        }
    }

    static func restore() {
        let domain = "gui/\(getuid())"
        let service = "\(domain)/com.apple.rcd"
        guard suspended || !isLoaded(service: service) else { return }
        let (status, err) = run(["bootstrap", domain, plistPath])
        if status == 0 {
            print("🔊 com.apple.rcd restored")
        } else {
            print("⚠️ Could not restore com.apple.rcd (launchctl exit=\(status)): \(err) — next login will re-register it")
        }
        suspended = false
    }

    private static func isLoaded(service: String) -> Bool {
        let (status, _) = run(["print", service], captureStderr: false)
        return status == 0
    }

    private static func run(_ args: [String], captureStderr: Bool = true) -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = captureStderr ? errPipe : Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let errData = captureStderr ? errPipe.fileHandleForReading.readDataToEndOfFile() : Data()
            let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (proc.terminationStatus, errStr)
        } catch {
            return (-1, "\(error)")
        }
    }
}
