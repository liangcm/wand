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
        let currentPosition = CGEvent(source: nil)?.location ?? .zero
        
        // Mouse down
        guard let downEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: currentPosition, mouseButton: .left) else {
            return
        }
        downEvent.post(tap: CGEventTapLocation.cghidEventTap)
        
        // Small delay
        usleep(10000) // 10ms
        
        // Mouse up
        guard let upEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: currentPosition, mouseButton: .left) else {
            return
        }
        upEvent.post(tap: CGEventTapLocation.cghidEventTap)
    }
    
    func mouseDown() {
        let currentPosition = CGEvent(source: nil)?.location ?? .zero
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: currentPosition, mouseButton: .left) else {
            return
        }
        event.post(tap: CGEventTapLocation.cghidEventTap)
    }
    
    func mouseUp() {
        let currentPosition = CGEvent(source: nil)?.location ?? .zero
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: currentPosition, mouseButton: .left) else {
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
