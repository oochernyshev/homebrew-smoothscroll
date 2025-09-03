import Foundation
import CoreGraphics

// MARK: - Configuration Constants
struct Config {
    /// Exponential smoothing factor (closer to 1.0 = smoother but slower response)
    static let smoothingFactor: CGFloat = 0.9

    /// Scale multiplier for the final scroll delta
    static let scrollScale: CGFloat = 1.0

    /// Run loop mode
    static let runLoopMode: CFRunLoopMode = .commonModes
}

// MARK: - Scroll Smoother
class ScrollSmoother {
    private var velocity: CGFloat = 0
    private var lastTime: CFTimeInterval = CACurrentMediaTime()

    func smooth(delta: CGFloat) -> CGFloat {
        let now = CACurrentMediaTime()
        let dt = now - lastTime
        lastTime = now

        // Apply exponential smoothing
        velocity = velocity * Config.smoothingFactor + delta * (1.0 - Config.smoothingFactor)

        // Apply scale and normalize by frame rate (~60fps)
        return velocity * Config.scrollScale * CGFloat(dt * 60.0)
    }
}

// MARK: - Event Handling
let smoother = ScrollSmoother()

func eventCallback(proxy: CGEventTapProxy,
                   type: CGEventType,
                   event: CGEvent,
                   refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard type == .scrollWheel else {
        return Unmanaged.passUnretained(event)
    }

    let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
    let smoothDY = smoother.smooth(delta: CGFloat(dy))

    // Block original event and inject smoothed one
    if let newEvent = CGEvent(scrollWheelEvent2Source: nil,
                              units: .pixel,
                              wheelCount: 1,
                              wheel1: Int32(smoothDY),
                              wheel2: 0,
                              wheel3: 0) {
        newEvent.post(tap: .cgAnnotatedSessionEventTap)
    }

    return nil
}

// MARK: - Event Tap Setup
let mask = (1 << CGEventType.scrollWheel.rawValue)
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                  place: .headInsertEventTap,
                                  options: .defaultTap,
                                  eventsOfInterest: CGEventMask(mask),
                                  callback: eventCallback,
                                  userInfo: nil) else {
    fatalError("Failed to create event tap. Check Accessibility permissions.")
}

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, Config.runLoopMode)
CGEvent.tapEnable(tap: tap, enable: true)
CFRunLoopRun()
