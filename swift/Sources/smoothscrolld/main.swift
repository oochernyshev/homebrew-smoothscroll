import Foundation
import CoreGraphics
import QuartzCore
import Darwin      // for setbuf

// Unbuffer stdout so prints show immediately even under launchd
setbuf(__stdoutp, nil)

// MARK: - Version / CLI
let appVersion: String = "0.2.14"
let args = CommandLine.arguments
let debugEnabled = true

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

// MARK: - Config
struct Config {
    // Time constants (seconds): smaller = snappier, larger = smoother
    static let tauTrackpad: CFTimeInterval = 0.035
    static let tauMouse:    CFTimeInterval = 0.090

    // Gain per device (tweak to taste)
    static let gainTrackpad: CGFloat = 1.0
    static let gainMouse:    CGFloat = 0.7

    // Minimal “nudge” when we’d otherwise emit 0 but user is scrolling
    static let minEmitEpsilon: CGFloat = 0.25 // in units of step (pixel/line)

    // Clamp per event to avoid huge spikes
    static let maxEmitPerEvent: Int32 = 100

    // Run loop mode
    static let runLoopMode: CFRunLoopMode = .commonModes
}

// Tag for synthetic events so we can ignore them inside the tap
private let kSyntheticTag: Int64 = 0x5343524F4C // "SCROL"

// MARK: - Scroll Smoother
final class ScrollSmoother {
    private var lastTime: CFTimeInterval = CACurrentMediaTime()
    private var filtered: CGFloat = 0         // low-pass output
    private var accumulator: CGFloat = 0      // carries fractional remainder

    // rate-independent one-pole LPF with accumulator → integer steps
    func step(delta: CGFloat, tau: CFTimeInterval, gain: CGFloat, stepUnit: CGFloat) -> Int32 {
        let now = CACurrentMediaTime()
        let dt = max(1e-4, now - lastTime)    // protect against 0
        lastTime = now

        // 1st-order low-pass: y += a * (x - y), a = 1 - exp(-dt/tau)
        let alpha = 1.0 - CGFloat(exp(-dt / tau))
        filtered += alpha * (delta - filtered)

        // accumulate (apply gain)
        accumulator += filtered * gain

        // How many whole stepUnits (pixels or lines) can we emit?
        let rawSteps = accumulator / stepUnit
        var emit = Int32(rawSteps.rounded(.towardZero))

        // If user is scrolling but rounding killed it, nudge ±1
        if emit == 0 && abs(filtered) / stepUnit >= Config.minEmitEpsilon {
            emit = (filtered > 0) ? 1 : -1
        }

        // Clamp to sane range
        emit = max(-Config.maxEmitPerEvent, min(Config.maxEmitPerEvent, emit))

        // Remove emitted portion from accumulator
        accumulator -= CGFloat(emit) * stepUnit
        return emit
    }

    // Reset between gestures if needed
    func reset() {
        filtered = 0
        accumulator = 0
        lastTime = CACurrentMediaTime()
    }
}

let smoother = ScrollSmoother()
var gTap: CFMachPort? = nil

// MARK: - Event Callback
func eventCallback(proxy: CGEventTapProxy,
                   type: CGEventType,
                   event: CGEvent,
                   refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {

    // Re-enable tap if the system disabled it
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if debugEnabled { print("Event tap disabled (\(type.rawValue)). Re-enabling…") }
        if let tap = gTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    guard type == .scrollWheel else {
        return Unmanaged.passUnretained(event)
    }

    // Ignore our own synthetic events to avoid feedback
    if event.getIntegerValueField(.eventSourceUserData) == kSyntheticTag {
        return Unmanaged.passUnretained(event)
    }

    // Pass through momentum phase (let macOS inertia do its thing)
    let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
    if momentumPhase != 0 {
        // Optional: reset our internal state between gestures
        smoother.reset()
        return Unmanaged.passUnretained(event)
    }

    // Trackpad gesture phase: reset when a new gesture begins
    let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
    if phase == 1 { // kCGScrollPhaseBegan == 1
        smoother.reset()
    }

    // Detect device type (continuous devices are usually trackpads)
    let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
    let units: CGScrollEventUnit = isContinuous ? .pixel : .line
    let tau  = isContinuous ? Config.tauTrackpad  : Config.tauMouse
    let gain = isContinuous ? Config.gainTrackpad : Config.gainMouse
    let stepUnit: CGFloat = 1.0 // 1 pixel or 1 line per integer tick

    // Read the original delta (prefer fixed → point → legacy)
    let dyFixed  = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
    let dyPoint  = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
    let dyLegacy = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
    let dy = (dyFixed != 0.0) ? dyFixed : (dyPoint != 0.0 ? dyPoint : dyLegacy)

    if dy == 0.0 {
        return Unmanaged.passUnretained(event)
    }
    if debugEnabled { print("RAW dy: \(dy)  phase:\(phase) cont:\(isContinuous)") }

    // Compute smoothed integer steps to emit
    let emitSteps = smoother.step(delta: CGFloat(dy),
                                  tau: tau,
                                  gain: gain,
                                  stepUnit: stepUnit)

    if debugEnabled { print("emitSteps: \(emitSteps)") }

    // If nothing to emit this tick, swallow the original and wait to accumulate
    if emitSteps == 0 {
        return nil
    }

    // Synthesize a new scroll event with our steps
    if let src = CGEventSource(stateID: .hidSystemState),
       let newEvent = CGEvent(scrollWheelEvent2Source: src,
                              units: units,
                              wheelCount: 1,
                              wheel1: emitSteps,
                              wheel2: 0,
                              wheel3: 0) {

        // Preserve common flags that affect behavior
        newEvent.setIntegerValueField(.keyboardEventAutorepeat, value: event.getIntegerValueField(.keyboardEventAutorepeat))
        newEvent.setIntegerValueField(.eventSourceUserData, value: kSyntheticTag)

        // Post at HID tap so it behaves like a real device event
        newEvent.post(tap: .cghidEventTap)
        return nil
    }

    // Fallback: pass original event if synth fails
    return Unmanaged.passUnretained(event)
}

// MARK: - Tap Setup
let mask: CGEventMask = (1 << CGEventType.scrollWheel.rawValue)
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                  place: .headInsertEventTap,
                                  options: .defaultTap,
                                  eventsOfInterest: mask,
                                  callback: eventCallback,
                                  userInfo: nil) else {
    fatalError("Failed to create event tap. Check Accessibility + Input Monitoring permissions.")
}
gTap = tap

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, Config.runLoopMode)
CGEvent.tapEnable(tap: tap, enable: true)

print("Starting smoothscrolld \(appVersion) — OK")
CFRunLoopRun()
