import Foundation
import CoreGraphics
import QuartzCore   // for CACurrentMediaTime()

// MARK: - Version
let appVersion: String = "0.2.6" // can be injected via compiler flags later

// MARK: - CLI Flags
let args = CommandLine.arguments
let debugEnabled = args.contains("--debug")

if args.contains("--version") {
    print("smoothscrolld \(appVersion)")
    exit(0)
}

if args.contains("--help") {
    print("""
    smoothscrolld - smooth scrolling daemon for macOS

    Options:
      --version   Print version and exit
      --debug     Enable debug logging
      --help      Show this message
    """)
    exit(0)
}

// MARK: - Configuration Constants
struct Config {
    /// Exponential smoothing factor (closer to 1.0 = smoother but slower response)
    static let smoothingFactor: CGFloat = 0.9

    /// Scale multiplier for the final scroll delta
    static let scrollScale: CGFloat = 1.0

    /// Scroll units: .line (typical mice) or .pixel (trackpads)
    static let scrollUnits: CGScrollEventUnit = .line

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

    // Original delta
    let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)

    // Smooth delta
    let smoothDY = smoother.smooth(delta: CGFloat(dy))

    if debugEnabled {
        print("Scroll delta: \(dy) → smoothed: \(smoothDY)")
    }

    // Scale up if too small (avoid rounding to zero)
    let adjusted = max(min(smoothDY * 10, 100), -100)  // clamp to ±100

    if let newEvent = CGEvent(scrollWheelEvent2Source: nil,
                              units: .pixel,   // use pixel for trackpads
                              wheelCount: 1,
                              wheel1: Int32(adjusted),
                              wheel2: 0,
                              wheel3: 0) {
        // Post at hardware event tap
        newEvent.post(tap: .cghidEventTap)
        return nil
    }

    // Fallback: pass original event
    return Unmanaged.passUnretained(event)
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
