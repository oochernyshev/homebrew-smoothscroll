import Foundation
import CoreGraphics
import QuartzCore
import Darwin   // setbuf

// Flush prints immediately (helps when launched via launchd)
setbuf(__stdoutp, nil)

// MARK: - Version / CLI
let appVersion: String = "0.2.15"
let args = CommandLine.arguments
let debugEnabled = true
if args.contains("--version") { print("smoothscrolld \(appVersion)"); exit(0) }
if args.contains("--help") {
    print("""
    smoothscrolld - smooth scrolling daemon for macOS

    Options:
      --version   Print version and exit
      --debug     Enable debug logging
      --help      Show this message
    """); exit(0)
}

// MARK: - Config
struct Config {
    // Trackpad: just pass through (macOS already smooth), but detect and reset state
    static let tauTrackpad: CFTimeInterval = 0.035
    static let gainTrackpad: CGFloat = 1.0

    // Mouse wheel smoothing-as-animation:
    static let lineToPixels: CGFloat = 24.0          // pixels per "line" tick (tweak to taste)
    static let tauMouseAnim: CFTimeInterval = 0.12   // larger = longer ease-out
    static let timerHz: CFTimeInterval = 120.0       // how often to emit pixel deltas
    static let minRestPixels: CGFloat = 0.1          // stop timer when below this
    static let maxEmitPerTick: Int32 = 120           // safety clamp

    static let runLoopMode: CFRunLoopMode = .commonModes
}

// Tag for synthetic events so we ignore them inside the tap
private let kSyntheticTag: Int64 = 0x5343524F4C // "SCROL"

var gTap: CFMachPort? = nil

// MARK: - Posting helper
@inline(__always)
func postPixelScroll(_ dy: Int32) {
    guard dy != 0 else { return }
    if let src = CGEventSource(stateID: .hidSystemState),
       let ev = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1,
                        wheel1: dy, wheel2: 0, wheel3: 0) {
        ev.setIntegerValueField(.eventSourceUserData, value: kSyntheticTag)
        ev.post(tap: .cghidEventTap)
    }
}

// MARK: - Wheel animator (mouse only)
final class WheelAnimator {
    private var remaining: CGFloat = 0      // pixels left to emit (signed)
    private var accumulator: CGFloat = 0    // holds fractional pixels between posts
    private var lastTime: CFTimeInterval = CACurrentMediaTime()
    private var timer: CFRunLoopTimer?

    func addLines(_ lines: Int32) {
        remaining += CGFloat(lines) * Config.lineToPixels
        startTimerIfNeeded()
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        lastTime = CACurrentMediaTime()
        let interval = 1.0 / Config.timerHz
        timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault,
                                                CFAbsoluteTimeGetCurrent() + interval,
                                                interval, 0, 0) { [weak self] _ in
            self?.tick()
        }
        if let t = timer {
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, Config.runLoopMode)
        }
    }

    private func stopTimerIfIdle() {
        if abs(remaining) < Config.minRestPixels && abs(accumulator) < Config.minRestPixels {
            if let t = timer { CFRunLoopTimerInvalidate(t) }
            timer = nil
            remaining = 0
            accumulator = 0
        }
    }

    private func tick() {
        // Exponential ease-out: move a fraction of what's remaining each tick
        let now = CACurrentMediaTime()
        let dt = max(1e-4, now - lastTime)
        lastTime = now

        let alpha = 1.0 - CGFloat(exp(-dt / Config.tauMouseAnim))
        let move = remaining * alpha
        remaining -= move
        accumulator += move

        // Emit integer pixels this tick
        var emit = Int32(accumulator.rounded(.towardZero))
        if emit != 0 {
            // Clamp spikes
            emit = max(-Config.maxEmitPerTick, min(Config.maxEmitPerTick, emit))
            accumulator -= CGFloat(emit)
            postPixelScroll(emit)
            if debugEnabled { print("anim emit: \(emit), remaining: \(remaining), acc: \(accumulator)") }
        }

        stopTimerIfIdle()
    }

    func reset() {
        remaining = 0
        accumulator = 0
        lastTime = CACurrentMediaTime()
    }
}

let mouseAnimator = WheelAnimator()

// MARK: - Event Callback
func eventCallback(proxy: CGEventTapProxy,
                   type: CGEventType,
                   event: CGEvent,
                   refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {

    // Re-enable tap if system disabled it
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = gTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    guard type == .scrollWheel else {
        return Unmanaged.passUnretained(event)
    }

    // Ignore our synthetic events
    if event.getIntegerValueField(.eventSourceUserData) == kSyntheticTag {
        return Unmanaged.passUnretained(event)
    }

    // Let native momentum glide pass through unchanged
    let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
    if momentumPhase != 0 {
        mouseAnimator.reset()
        return Unmanaged.passUnretained(event)
    }

    // Detect device kind
    let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0

    // New gesture on trackpads resets state (mouse path uses the animator)
    let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
    if phase == 1 { // kCGScrollPhaseBegan
        mouseAnimator.reset()
    }

    if isContinuous {
        // TRACKPAD: pass through (already smooth); you can optionally tweak via gain if desired
        return Unmanaged.passUnretained(event)
    } else {
        // MOUSE: consume the line event and animate pixel deltas instead

        // Prefer legacy integer line delta for mice
        var linesI64 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        if linesI64 == 0 {
            // Fallbacks (rare on mice)
            let dyFixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            let dyPoint = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let dy = (dyFixed != 0.0) ? dyFixed : dyPoint
            linesI64 = Int64(dy.rounded())
        }

        if linesI64 == 0 {
            return Unmanaged.passUnretained(event)
        }

        // Clamp to Int32 for wheel1 + animator input
        let lines = Int32(clamping: linesI64)

        if debugEnabled {
            print("mouse lines: \(lines) (raw64: \(linesI64))")
        }

        mouseAnimator.addLines(lines)
        // Swallow the original line event (we'll emit pixels over time)
        return nil
    }
}

// MARK: - Event Tap Setup
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
