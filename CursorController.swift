//
//  CursorController.swift
//  Wand
//
//  Controls cursor movement and clicking using CGEvent
//

import CoreGraphics
import CoreFoundation
import Foundation
import AppKit
import ApplicationServices

class CursorController {
    private let sensitivity: CGFloat = 2.0
    private let acceleration: CGFloat = 1.2
    private let remotePositionCacheInterval: TimeInterval = 0.15
    private let mouseEventSource: CGEventSource? = {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        return source
    }()
    private var lastPostedCursorPosition: CGPoint?
    private var lastPostedCursorPositionTime: Date = .distantPast
    private var mouseEventSequence: Int64 = 1
    
    var isDragging: Bool = false
    var isClickActive: Bool = false
    
    // MARK: - Helper Functions
    
    /// Active display bounds in the same global display coordinate space used by CGEvent.
    private func activeDisplayBounds() -> [CGRect] {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        let result = displays.withUnsafeMutableBufferPointer { buffer in
            CGGetActiveDisplayList(UInt32(buffer.count), buffer.baseAddress, &displayCount)
        }
        guard result == .success else { return [] }
        return displays.prefix(Int(displayCount)).map { CGDisplayBounds($0) }
    }

    private func boundsContaining(_ point: CGPoint, in bounds: [CGRect]) -> CGRect? {
        bounds.first { frame in
            point.x >= frame.minX &&
            point.x < frame.maxX &&
            point.y >= frame.minY &&
            point.y < frame.maxY
        }
    }

    private func clamp(_ point: CGPoint, to frame: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, frame.minX), frame.maxX - 1),
            y: min(max(point.y, frame.minY), frame.maxY - 1)
        )
    }

    private func currentCursorPosition() -> CGPoint {
        let real = CGEvent(source: nil)?.location

        // The cache smooths our own event stream, but the user may have moved the cursor with
        // the built-in trackpad/mouse since we last posted — if the real cursor has drifted
        // away from what we posted, the cache is stale and must be dropped, or the next remote
        // move would yank the cursor back to the old spot.
        if let cached = lastPostedCursorPosition,
           Date().timeIntervalSince(lastPostedCursorPositionTime) < remotePositionCacheInterval {
            if let real = real, hypot(real.x - cached.x, real.y - cached.y) > 8 {
                return real
            }
            return cached
        }

        if let real = real {
            return real
        }

        // Last-resort Cocoa→Quartz flip. Quartz's origin is anchored to the PRIMARY display
        // (screens.first), not NSScreen.main (the key window's screen).
        let nsLocation = NSEvent.mouseLocation
        if let primary = NSScreen.screens.first {
            return CGPoint(x: nsLocation.x, y: primary.frame.height - nsLocation.y)
        }
        return CGPoint(x: nsLocation.x, y: nsLocation.y)
    }
    
    // MARK: - Cursor Movement
    
    // Returns true if cursor is at an edge of the current screen and would be clamped
    @discardableResult
    func moveCursor(deltaX: CGFloat, deltaY: CGFloat) -> (clampedX: Bool, clampedY: Bool) {
        let scaledDeltaX = deltaX * sensitivity * (abs(deltaX) > 5 ? acceleration : 1.0)
        let scaledDeltaY = deltaY * sensitivity * (abs(deltaY) > 5 ? acceleration : 1.0)

        let beforePosition = currentCursorPosition()
        
        let displays = activeDisplayBounds()
        let currentBounds = boundsContaining(beforePosition, in: displays)
        
        let rawTargetPosition = CGPoint(
            x: beforePosition.x + scaledDeltaX,
            y: beforePosition.y + scaledDeltaY
        )
        
        let targetPosition: CGPoint
        if boundsContaining(rawTargetPosition, in: displays) != nil {
            targetPosition = rawTargetPosition
        } else if let currentBounds = currentBounds {
            targetPosition = clamp(rawTargetPosition, to: currentBounds)
        } else {
            targetPosition = rawTargetPosition
        }

        let clampedX = abs(targetPosition.x - rawTargetPosition.x) > 0.001
        let clampedY = abs(targetPosition.y - rawTargetPosition.y) > 0.001
        
        let eventType: CGEventType = isDragging ? .leftMouseDragged : .mouseMoved
        guard let event = CGEvent(mouseEventSource: mouseEventSource, mouseType: eventType, mouseCursorPosition: targetPosition, mouseButton: .left) else {
            return (clampedX, clampedY)
        }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(scaledDeltaX.rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(scaledDeltaY.rounded()))
        event.post(tap: CGEventTapLocation.cghidEventTap)
        lastPostedCursorPosition = targetPosition
        lastPostedCursorPositionTime = Date()

        return (clampedX, clampedY)
    }
    
    func performClick() {
        let currentPosition = currentCursorPosition()
        if performFrontmostAccessibilityPress(at: currentPosition) {
            return
        }

        let isDouyin = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.bytedance.douyin.desktop"
        let eventNumber = mouseEventSequence
        mouseEventSequence &+= 1

        // Chromium-based apps such as Douyin expect a complete pointer sequence. Reassert
        // hover at the cached cursor position, then send a matched down/up pair with a real
        // click-state and event number instead of two anonymous 10ms Quartz events.
        if isDouyin,
           let hoverEvent = CGEvent(mouseEventSource: mouseEventSource,
                                    mouseType: .mouseMoved,
                                    mouseCursorPosition: currentPosition,
                                    mouseButton: .left) {
            hoverEvent.setIntegerValueField(.mouseEventDeltaX, value: 0)
            hoverEvent.setIntegerValueField(.mouseEventDeltaY, value: 0)
            hoverEvent.post(tap: .cghidEventTap)
            usleep(8000)
        }
        
        // Mouse down
        guard let downEvent = CGEvent(mouseEventSource: mouseEventSource, mouseType: .leftMouseDown, mouseCursorPosition: currentPosition, mouseButton: .left) else {
            return
        }
        downEvent.setIntegerValueField(.mouseEventClickState, value: 1)
        downEvent.setIntegerValueField(.mouseEventNumber, value: eventNumber)
        downEvent.post(tap: CGEventTapLocation.cghidEventTap)
        
        // Douyin drops unrealistically short synthetic presses; use a normal physical-click
        // duration there while retaining the snappier path for other applications.
        usleep(isDouyin ? 55_000 : 15_000)
        
        // Mouse up
        guard let upEvent = CGEvent(mouseEventSource: mouseEventSource, mouseType: .leftMouseUp, mouseCursorPosition: currentPosition, mouseButton: .left) else {
            return
        }
        upEvent.setIntegerValueField(.mouseEventClickState, value: 1)
        upEvent.setIntegerValueField(.mouseEventNumber, value: eventNumber)
        upEvent.post(tap: CGEventTapLocation.cghidEventTap)
        rmDebug("🖱 Posted complete click app=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown") x=\(Int(currentPosition.x)) y=\(Int(currentPosition.y))")
    }

    /// Douyin ignores the HID-layer synthetic clicks used by the normal trackpad path on
    /// some releases. A deliberate double press of the remote's center button uses this
    /// independent WindowServer session path to deliver one plain left click.
    func performDouyinSessionClick() {
        let currentPosition = currentCursorPosition()
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0

        guard let downEvent = CGEvent(mouseEventSource: source,
                                      mouseType: .leftMouseDown,
                                      mouseCursorPosition: currentPosition,
                                      mouseButton: .left),
              let upEvent = CGEvent(mouseEventSource: source,
                                    mouseType: .leftMouseUp,
                                    mouseCursorPosition: currentPosition,
                                    mouseButton: .left) else { return }
        downEvent.setIntegerValueField(.mouseEventClickState, value: 1)
        upEvent.setIntegerValueField(.mouseEventClickState, value: 1)
        downEvent.post(tap: .cgSessionEventTap)
        usleep(80_000)
        upEvent.post(tap: .cgSessionEventTap)
        rmDebug("🖱 Douyin center double press → session left click x=\(Int(currentPosition.x)) y=\(Int(currentPosition.y))")
    }

    /// Chromium exposes many controls as accessibility buttons even when it ignores a Quartz
    /// click. Prefer AXPress for the exact element under the pointer in Douyin, then fall back
    /// to the complete mouse sequence above for video surfaces and non-AX elements.
    private func performFrontmostAccessibilityPress(at point: CGPoint) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.bytedance.douyin.desktop" else {
            return false
        }
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
              let element else {
            return false
        }
        var actionNames: CFArray?
        guard AXUIElementCopyActionNames(element, &actionNames) == .success,
              let names = actionNames as? [String],
              names.contains(kAXPressAction as String) else {
            return false
        }
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if result == .success {
            rmDebug("🖱 Douyin click delivered through AXPress x=\(Int(point.x)) y=\(Int(point.y))")
            return true
        }
        return false
    }
    
    func mouseDown() {
        let currentPosition = currentCursorPosition()
        guard let event = CGEvent(mouseEventSource: mouseEventSource, mouseType: .leftMouseDown, mouseCursorPosition: currentPosition, mouseButton: .left) else {
            return
        }
        event.post(tap: CGEventTapLocation.cghidEventTap)
    }
    
    func mouseUp() {
        let currentPosition = currentCursorPosition()
        guard let event = CGEvent(mouseEventSource: mouseEventSource, mouseType: .leftMouseUp, mouseCursorPosition: currentPosition, mouseButton: .left) else {
            return
        }
        event.post(tap: CGEventTapLocation.cghidEventTap)
    }
    
    func scroll(deltaX: Int32, deltaY: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0) else {
            return
        }
        event.post(tap: CGEventTapLocation.cghidEventTap)
    }
}
