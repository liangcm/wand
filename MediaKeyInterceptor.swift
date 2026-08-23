//
//  MediaKeyInterceptor.swift
//  Wand
//
//  Intercepts system media key events at HID level to reliably prevent default handling.
//  Re-enables tap when disabled by timeout/sleep and on wake.
//

import Cocoa
import CoreGraphics

// IOKit/hidsystem/ev_keymap.h exports this as NX_POWER_KEY (6), not NX_KEYTYPE_POWER.
private let wandNXPowerKey = Int32(6)
private let wandVirtualPowerKeyCode = Int64(0x7F)

class MediaKeyInterceptor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var wakeObserver: NSObjectProtocol?
    
    var onMediaKey: ((MediaKeyType) -> Bool)?
    
    enum MediaKeyType {
        case playPause, next, previous, volumeUp, volumeDown, mute, power
    }
    
    func start() {
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << 14) // NX_SYSDEFINED
        
        // HID-level tap intercepts media keys before the system handles them (more reliable than session tap).
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
                return interceptor.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            rmDebug("⚠️ Media key event tap could not be created")
            return
        }
        
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            rmDebug("🛡 Media key event tap enabled (system-defined + keyboard power)")
        }
        
        // Re-enable tap after sleep/wake (system often disables taps during sleep).
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reenableTap()
        }
    }
    
    func stop() {
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }
    
    /// Re-enable the event tap after it was disabled by timeout or sleep.
    func reenableTap() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap when system disables it (timeout or user input); then consume the event.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            rmDebug("⚠️ Media key event tap disabled; re-enabling")
            reenableTap()
            return nil
        }

        // A2854 can surface its power control as the keyboard Power virtual key (0x7F),
        // independently of the Consumer-page HID value that Wand has already seized.
        // Swallow both press and release before WindowServer can open the shutdown panel.
        if type == .keyDown || type == .keyUp,
           event.getIntegerValueField(.keyboardEventKeycode) == wandVirtualPowerKeyCode {
            rmDebug("🛡 Consumed keyboard power event (type=\(type.rawValue))")
            _ = onMediaKey?(.power)
            return nil
        }
        
        // NX_SYSDEFINED = 14
        guard type.rawValue == 14 else {
            return Unmanaged.passRetained(event)
        }
        
        // Get NSEvent to parse the media key
        guard let nsEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passRetained(event)
        }
        
        // Parse the key code from data1
        let keyCode = Int32((nsEvent.data1 & 0xFFFF0000) >> 16)
        let keyFlags = nsEvent.data1 & 0x0000FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        let isKeyDown = keyState == 0x0A

        // The Siri Remote also emits a native system power key alongside its HID button.
        // Consume both down and up states when Wand owns it, otherwise macOS opens the
        // shutdown/restart/sleep confirmation panel before our long-press sleep runs.
        if keyCode == wandNXPowerKey,
           let handler = onMediaKey,
           handler(.power) {
            rmDebug("🛡 Consumed NX power event (subtype=\(nsEvent.subtype.rawValue), state=\(keyState))")
            return nil
        }

        // Check subtype 8 = media key event. Power is deliberately handled above because
        // some macOS/A2854 combinations deliver it under a different system subtype.
        guard nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passRetained(event)
        }

        // Only handle key down events
        guard isKeyDown else {
            return Unmanaged.passRetained(event)
        }
        
        // Identify the media key
        var mediaKey: MediaKeyType?
        switch keyCode {
        case NX_KEYTYPE_PLAY:
            mediaKey = .playPause
        case NX_KEYTYPE_NEXT, NX_KEYTYPE_FAST:
            mediaKey = .next
        case NX_KEYTYPE_PREVIOUS, NX_KEYTYPE_REWIND:
            mediaKey = .previous
        case NX_KEYTYPE_SOUND_UP:
            mediaKey = .volumeUp
        case NX_KEYTYPE_SOUND_DOWN:
            mediaKey = .volumeDown
        case NX_KEYTYPE_MUTE:
            mediaKey = .mute
        case wandNXPowerKey:
            mediaKey = .power
        default:
            break
        }
        
        if let key = mediaKey, let handler = onMediaKey, handler(key) {
            return nil // Consume event
        }
        
        return Unmanaged.passRetained(event)
    }
    
    deinit {
        stop()
    }
}
