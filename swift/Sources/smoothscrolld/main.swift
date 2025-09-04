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

    /// Scroll units for synthetic events
    static let scrollUnits: CGScrollEventUnit = .pixel

    /// Run loop mode
    static let runLoopMode: CFRunLoopMode = .commonModes
}

// Tag used to mark our synthetic events so we can ignore them in the tap.
private let kSyntheticTag: Int64 = 0x5343524F4C // "SCROL" in ASCII

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

        // Apply scale and normalize by ~60fps
        return velocity * Config.scrollScale * CGFloat(dt * 60.0)
    }
}

// MARK: - Event Handling
let smoother = ScrollSmoother()

func eventCallback(proxy: CGEventTapProxy,
                   type: CGEventType,
                   event: CGEvent,
                   refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {

    // If the tap gets disabled, just pass events through.
    guard type == .scrollWheel else {
        return Unmanaged.passUnretained(event)
    }

    // Ignore our own synthetic events so we don't create a feedback loop.
    if event.getIntegerValueField(.eventSourceUserData) == kSyntheticTag {
        return Unmanaged.passUnretained(event)
    }

    // Read original delta (prefer fixed → point → legacy)
    let dyFixed  = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
    let dyPoint  = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
    let dyLegacy = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
    let dy = (dyFixed != 0.0) ? dyFixed : (dyPoint != 0.0 ? dyPoint : dyLegacy)

    // Ignore no-op events
    if dy == 0.0 {
        return Unmanaged.passUnretained(event)
    }

    if debugEnabled {
        print("RAW delta: \(dy)")
    }

    // Smooth delta
    let smoothDY = smoother.smooth(delta: CGFloat(dy))

    if debugEnabled {
        print("Scroll delta: \(dy) → smoothed: \(smoothDY)")
    }

    // Scale & clamp (avoid rounding to 0 and crazy spikes)
    let adjusted = max(min(smoothDY * 10, 100), -100)

    // Create a new synthetic scroll event (tagged) and post it
    if let src = CGEventSource(stateID: .hidSystemState),
       let newEvent = CGEvent(scrollWheelEvent2Source: src,
                              units: Config.scrollUnits,
                              wheelCount: 1,
                              wheel1: Int32(adjusted),
                              wheel2: 0,
                              wheel3: 0) {

        // Mark event so our tap will ignore it
        newEvent.setIntegerValueField(.eventSourceUserData, value: kSyntheticTag)

        // Post at hardware tap so it behaves like a real scroll
        newEvent.post(tap: .cghidEventTap)

        // Drop original event to avoid double-scrolling
        return nil
    }

    // Fallback: pass original event if we couldn't synthesize
    return Unmanaged.passUnretained(event)
}

// MARK: - Event Tap Setup
let mask: CGEventMask = (1 << CGEventType.scrollWheel.rawValue)
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                  place: .headInsertEventTap,
                                  options: .defaultTap,
                                  eventsOfInterest: mask,
                                  callback: eventCallback,
                                  userInfo: nil) else {
    fatalError("Failed to create event tap. Check Accessibility permissions.")
}

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, Config.runLoopMode)
CGEvent.tapEnable(tap: tap, enable: true)

print("Starting smoothscrolld service - OK")
CFRunLoopRun()
