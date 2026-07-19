//
//  TouchHandler.swift
//  Wand
//
//  Handles Siri Remote trackpad input using Apple's private MultitouchSupport.framework
//

import Foundation
import CoreGraphics
import AppKit
import Darwin

private func touchCallback(device: MTDevice?,
                           touches: UnsafeMutablePointer<MTTouch>?,
                           numTouches: Int,
                           timestamp: Double,
                           frame: Int,
                           refcon: UnsafeMutableRawPointer?) {
    guard let refcon = refcon else { return }
    let handler = Unmanaged<TouchHandler>.fromOpaque(refcon).takeUnretainedValue()
    handler.handleTouches(touches: touches, count: numTouches, timestamp: timestamp)
}

class TouchHandler {
    
    /// mach_absolute_time() is in machine-dependent units; convert to seconds via timebase.
    private static let machTimebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t(numer: 0, denom: 0)
        if mach_timebase_info(&info) == 0 {
            return (info.numer, info.denom)
        }
        return (1, 1)
    }()
    
    private static func machDeltaToSeconds(from startMach: UInt64) -> Double {
        guard startMach > 0 else { return 0 }
        let now = mach_absolute_time()
        let delta = now >= startMach ? (now - startMach) : 0
        let nanos = delta * UInt64(Self.machTimebase.numer) / UInt64(Self.machTimebase.denom)
        return Double(nanos) / 1_000_000_000.0
    }
    
    private let cursorController: CursorController
    private var device: MTDevice?
    private var reconnectTimer: Timer?
    private var fastReconnectTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    
    var scrollScale: CGFloat = 150.0
    
    private var lastTouchPosition: CGPoint?
    private var lastTouchCount = 0
    private var lastTouchTime: UInt64 = 0
    private var touchStartTime: UInt64 = 0
    private var touchStartPosition: CGPoint = .zero
    
    private let cursorScale: CGFloat = 500.0
    private let tapMaxDuration: Double = 0.22
    private let tapMaxDistance: CGFloat = 0.07
    // Swipe detection: velocity-gated single-finger flick. Distance > 35% of trackpad in < 350ms,
    // with the dominant axis at least 2× the orthogonal axis (rejects diagonal wobble).
    private let swipeMinDistance: CGFloat = 0.35
    private let swipeMaxDuration: Double = 0.35
    private let swipeAxisRatio: CGFloat = 2.0
    // Lift-velocity gate: a deliberate flick lifts the finger while it's still moving fast,
    // whereas cursor gliding decelerates to a stop before lifting. Requiring recent speed at
    // lift keeps fast cursor moves from misfiring as swipe gestures (which would send the
    // mapped keys — F1/⌘C/… — into apps that reject them with the system alert sound).
    private let swipeMinLiftSpeed: CGFloat = 1.2   // trackpad widths per second, EMA-smoothed
    private var recentSpeed: CGFloat = 0
    private var lastFrameTimestamp: Double = 0
    // Isolation gates: moving the cursor across a screen on this tiny pad means BURSTS of fast
    // strokes (~100-200ms apart) whose lift kinematics match a flick exactly — speed alone can't
    // tell them apart (measured: cursor strokes lift at 3-5 widths/s too). A deliberate gesture
    // is an ISOLATED flick: quiet before (no touch for 0.4s) and quiet after (no follow-up
    // touch within 250ms). Burst strokes fail one or both, so they never fire actions.
    private let swipeQuietBefore: Double = 0.4
    private let swipeQuietAfter: Double = 0.25
    private var lastTouchEndTime: UInt64 = 0
    private var sessionIsolated = false
    private var pendingSwipe: DispatchWorkItem?
    private var hadMultipleFingersInSession = false

    // Multi-finger pinch-in detection. Scale-free: we track each touch's mean distance to the
    // group centroid ("spread") within a session and fire when it collapses to a fraction of
    // the peak seen. Using ≥3 fingers rather than exactly 4 because the Siri Remote's small
    // trackpad reports the 4th contact unreliably — a 4-finger pinch still registers this way.
    private let pinchMinFingers = 3
    private let pinchMinPeakSpread: CGFloat = 0.03   // must have genuinely spread out first
    private let pinchCollapseRatio: CGFloat = 0.55   // spread must fall to ≤55% of its peak
    private var pinchPeakSpread: CGFloat = 0
    private var pinchFired = false

    /// Fired on touch-up when a single-finger flick is detected. Dispatched on main.
    var onSwipe: ((SwipeDirection) -> Void)?
    /// Fired mid-gesture when a multi-finger pinch-in is detected. Dispatched on main.
    var onPinch: (() -> Void)?
    /// Returns whether tap-to-click is currently enabled; nil defaults to enabled.
    var isTapEnabled: (() -> Bool)?
    private let reconnectInterval: TimeInterval = 2.0
    private let idleTimeout: TimeInterval = 90.0
    private let touchStarvationThreshold: TimeInterval = 15.0

    init(cursorController: CursorController) {
        self.cursorController = cursorController
    }
    
    deinit {
        stop()
    }
    
    func start() {
        findAndStartDevice()
        startReconnectTimer()
        // Restart MT device after sleep (trackpad stops delivering until restarted).
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.restartTrackpadAfterWake()
        }
    }
    
    func stop() {
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        fastReconnectTimer?.invalidate()
        fastReconnectTimer = nil
        stopDevice()
    }
    
    /// Call when HID button activity is detected (e.g. after remote wake). Re-scans MT devices
    /// only when we don't have a device, so we can reattach if it reappeared. If we already
    /// have a working device, do nothing — restarting on every button press would break the trackpad.
    func tryReconnectTrackpad() {
        guard device == nil else { return }
        let doScan = { [weak self] in
            guard self?.device == nil else { return }
            self?.findAndStartDevice()
        }
        if Thread.isMainThread {
            doScan()
        } else {
            DispatchQueue.main.async { doScan() }
        }
        // Device may re-enumerate shortly after HID activity; retry once after a short delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { doScan() }
        // Poll more often for a limited time so we attach as soon as the trackpad reappears.
        fastReconnectTimer?.invalidate()
        let startDate = Date()
        fastReconnectTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if self.device != nil {
                timer.invalidate()
                self.fastReconnectTimer = nil
                return
            }
            if Date().timeIntervalSince(startDate) > 20 {
                timer.invalidate()
                self.fastReconnectTimer = nil
                return
            }
            self.findAndStartDevice()
        }
        if let timer = fastReconnectTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    private func restartTrackpadAfterWake() {
        stopDevice()
        findAndStartDevice()
    }
    
    private func findAndStartDevice() {
        guard let cfArray = MTDeviceCreateList()?.takeRetainedValue() else { return }
        let deviceList = cfArray as [MTDevice]
        // Find non-built-in device (Siri Remote)
        for dev in deviceList {
            if !MTDeviceIsBuiltIn(dev) {
                startDevice(dev)
                return
            }
        }
        // Fallback: use second device if available
        if deviceList.count > 1 {
            startDevice(deviceList[1])
        } else if device != nil {
            // Clear stale ref so next checkAndReconnect will retry when the remote reappears in the list.
            stopDevice()
        }
    }
    
    private func startDevice(_ dev: MTDevice) {
        stopDevice()
        device = dev
        
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        MTRegisterContactFrameCallbackWithRefcon(dev, touchCallback, refcon)
        MTDeviceStart(dev, 0)
        // Reset so we don't immediately re-enter starvation and restart every 2s when no touches yet.
        lastTouchTime = mach_absolute_time()
        print("📱 Trackpad device connected and started")
    }
    
    private func stopDevice() {
        guard let dev = device else { return }
        MTUnregisterContactFrameCallback(dev, touchCallback)
        MTDeviceStop(dev)
        device = nil
        
        print("📱 Trackpad device disconnected")
        lastTouchPosition = nil
        lastTouchCount = 0
        hadMultipleFingersInSession = false
    }
    
    private func startReconnectTimer() {
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: reconnectInterval, repeats: true) { [weak self] _ in
            self?.checkAndReconnect()
        }
        // Fire when app is in background (menu bar only); otherwise timer may not run.
        if let timer = reconnectTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    private func checkAndReconnect() {
        let timeSinceLastTouch = lastTouchTime == 0 ? 0 : Self.machDeltaToSeconds(from: lastTouchTime)

        guard let cfArray = MTDeviceCreateList()?.takeRetainedValue() else { return }
        let deviceCount = CFArrayGetCount(cfArray)

        // Restart if we have a device ref but the driver stopped (e.g. after remote sleep).
        if let dev = device, !MTDeviceIsRunning(dev) {
            findAndStartDevice()
            return
        }
        // Restart if we have a device but no touch events for a while (remote slept; no "remote wake" API).
        if device != nil && timeSinceLastTouch > touchStarvationThreshold {
            findAndStartDevice()
            return
        }
        if device == nil || (timeSinceLastTouch > idleTimeout && deviceCount > 1) {
            findAndStartDevice()
        }
    }
    
    func handleTouches(touches: UnsafeMutablePointer<MTTouch>?, count: Int, timestamp: Double) {
        lastTouchTime = mach_absolute_time()

        guard count > 0, let touchPtr = touches else {
            // Touch ended
            handleTouchEnd()
            lastTouchPosition = nil
            lastTouchCount = 0
            return
        }
        
        // Calculate average position of all active touches
        var avgX: Float = 0
        var avgY: Float = 0
        var activeTouchCount = 0
        
        for i in 0..<count {
            let touch = touchPtr[i]
            
            // Only process active touches
            if touch.state == MTTouchStateTouching || touch.state == MTTouchStateMakeTouch {
                avgX += touch.normalizedVector.position.x
                avgY += touch.normalizedVector.position.y
                activeTouchCount += 1
            }
        }
        
        guard activeTouchCount > 0 else {
            handleTouchEnd()
            lastTouchPosition = nil
            lastTouchCount = 0
            return
        }
        
        if activeTouchCount >= 2 {
            hadMultipleFingersInSession = true
        }

        avgX /= Float(activeTouchCount)
        avgY /= Float(activeTouchCount)
        
        let currentPos = CGPoint(x: CGFloat(avgX), y: CGFloat(avgY))
        
        // Handle touch start
        if lastTouchPosition == nil {
            // A new touch this soon after a swipe candidate means the candidate was one stroke
            // of a cursor-movement burst, not a gesture — kill it before its delay elapses.
            if let pending = pendingSwipe {
                pending.cancel()
                pendingSwipe = nil
                rmDebug("👟 swipe 取消（后续触摸到来 → 判定为光标连环划）")
            }
            let quiet = lastTouchEndTime == 0 ? Double.infinity : Self.machDeltaToSeconds(from: lastTouchEndTime)
            sessionIsolated = quiet >= swipeQuietBefore
            hadMultipleFingersInSession = false
            pinchPeakSpread = 0
            pinchFired = false
            recentSpeed = 0
            lastFrameTimestamp = timestamp
            touchStartTime = mach_absolute_time()
            touchStartPosition = currentPos
            lastTouchPosition = currentPos
            lastTouchCount = activeTouchCount
            return
        }

        // Multi-finger pinch-in: fingers spread out, then collapse toward their centroid.
        // Fires once per session; the ≥3-finger gate keeps it clear of 1-finger cursor and
        // 2-finger scroll. NOTE: unverified — during testing the Siri Remote trackpad never
        // emitted touch frames, so this path has never actually run on hardware.
        if activeTouchCount >= pinchMinFingers && !pinchFired {
            var spread: CGFloat = 0
            var counted = 0
            for i in 0..<count {
                let t = touchPtr[i]
                guard t.state == MTTouchStateTouching || t.state == MTTouchStateMakeTouch else { continue }
                spread += hypot(CGFloat(t.normalizedVector.position.x) - currentPos.x,
                                CGFloat(t.normalizedVector.position.y) - currentPos.y)
                counted += 1
            }
            if counted > 0 { spread /= CGFloat(counted) }
            pinchPeakSpread = max(pinchPeakSpread, spread)
            if pinchPeakSpread >= pinchMinPeakSpread && spread <= pinchPeakSpread * pinchCollapseRatio {
                pinchFired = true
                rmDebug(String(format: "🤏 pinch detected (fingers=%d peak=%.3f now=%.3f) → open panel",
                               activeTouchCount, pinchPeakSpread, spread))
                DispatchQueue.main.async { [weak self] in self?.onPinch?() }
            }
        }

        // Calculate delta
        let deltaX = currentPos.x - (lastTouchPosition?.x ?? currentPos.x)
        let deltaY = currentPos.y - (lastTouchPosition?.y ?? currentPos.y)

        // Track instantaneous speed (EMA) so touch-end can tell a flick from a glide-then-stop.
        let dt = timestamp - lastFrameTimestamp
        if dt > 0 && dt < 0.5 {
            let v = hypot(deltaX, deltaY) / CGFloat(dt)
            recentSpeed = 0.7 * recentSpeed + 0.3 * v
        }
        lastFrameTimestamp = timestamp


        // Process based on finger count: 1 finger = cursor, 2 fingers = scroll
        if activeTouchCount == 1 && lastTouchCount == 1 {
            let clamped = moveCursor(deltaX: deltaX, deltaY: deltaY)
            // Only advance touch tracking if cursor wasn't clamped in that direction
            if let lastPos = lastTouchPosition {
                let adjustedDeltaX = clamped.clampedX ? 0 : deltaX
                let adjustedDeltaY = clamped.clampedY ? 0 : deltaY
                lastTouchPosition = CGPoint(
                    x: lastPos.x + adjustedDeltaX,
                    y: lastPos.y + adjustedDeltaY
                )
            } else {
                lastTouchPosition = currentPos
            }
        } else if activeTouchCount == 2 && lastTouchCount == 2 {
            // Two fingers: always scroll regardless of mode
            performScroll(deltaX: deltaX, deltaY: deltaY)
            lastTouchPosition = currentPos
        } else {
            lastTouchPosition = currentPos
        }
        
        lastTouchCount = activeTouchCount
    }
    
    private func handleTouchEnd() {
        guard lastTouchPosition != nil else { return }
        lastTouchEndTime = mach_absolute_time()

        // Don't trigger tap if physical click button is active
        if cursorController.isClickActive {
            return
        }
        // Don't trigger tap after a multi-finger gesture (e.g. two-finger scroll)
        if hadMultipleFingersInSession {
            return
        }
        
        let duration = Self.machDeltaToSeconds(from: touchStartTime)
        let dx = (lastTouchPosition?.x ?? 0) - touchStartPosition.x
        let dy = (lastTouchPosition?.y ?? 0) - touchStartPosition.y
        let movement = hypot(dx, dy)

        // Swipe detection (flick). Fires before tap check; distance threshold is well above
        // tapMaxDistance, so a swipe can never also register as a tap.
        if duration < swipeMaxDuration && movement > swipeMinDistance {
            let absDx = abs(dx), absDy = abs(dy)
            let direction: SwipeDirection?
            if absDx > absDy * swipeAxisRatio {
                direction = dx > 0 ? .right : .left
            } else if absDy > absDx * swipeAxisRatio {
                // MultitouchSupport reports y increasing toward the top of the trackpad.
                direction = dy > 0 ? .up : .down
            } else {
                direction = nil
            }
            if let direction = direction {
                // Gate 1 — lift velocity: the finger must still be moving fast at lift.
                guard recentSpeed >= swipeMinLiftSpeed else {
                    rmDebug(String(format: "👟 swipe %@ 拦截（抬手速度 %.2f < %.2f → 移动光标）",
                                   "\(direction)", recentSpeed, swipeMinLiftSpeed))
                    return
                }
                // Gate 2 — quiet before: a stroke that follows another touch within 0.4s is
                // part of a cursor-movement burst, not a deliberate gesture.
                guard sessionIsolated else {
                    rmDebug(String(format: "👟 swipe %@ 拦截（前静默不足 → 光标连环划）", "\(direction)"))
                    return
                }
                // Gate 3 — quiet after: fire only if no follow-up touch arrives within 250ms.
                // touch-start cancels this work item, so burst-leading strokes never fire.
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.pendingSwipe = nil
                    rmDebug(String(format: "👟 swipe %@ 触发（速度 %.2f，距离 %.2f，时长 %.0fms，孤立）",
                                   "\(direction)", self.recentSpeed, movement, duration * 1000))
                    self.onSwipe?(direction)
                }
                pendingSwipe = work
                DispatchQueue.main.asyncAfter(deadline: .now() + swipeQuietAfter, execute: work)
                return
            }
        }

        if duration < tapMaxDuration && movement < tapMaxDistance {
            if isTapEnabled?() == false { return }   // tap-to-click 被用户关闭
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.cursorController.performClick()
            }
        }
    }
    
    private func moveCursor(deltaX: CGFloat, deltaY: CGFloat) -> (clampedX: Bool, clampedY: Bool) {
        let scaledX = deltaX * cursorScale
        let scaledY = -deltaY * cursorScale

        var clamped = (clampedX: false, clampedY: false)

        if Thread.isMainThread {
            clamped = cursorController.moveCursor(deltaX: scaledX, deltaY: scaledY)
        } else {
            DispatchQueue.main.sync {
                clamped = cursorController.moveCursor(deltaX: scaledX, deltaY: scaledY)
            }
        }

        return clamped
    }
    
    private func performScroll(deltaX: CGFloat, deltaY: CGFloat) {
        let scrollX = Int32(-deltaX * scrollScale)
        let scrollY = Int32(deltaY * scrollScale)
        
        DispatchQueue.main.async { [weak self] in
            self?.cursorController.scroll(deltaX: scrollX, deltaY: scrollY)
        }
    }
}
