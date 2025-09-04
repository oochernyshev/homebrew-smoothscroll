import Foundation
import CoreGraphics
import QuartzCore
import Darwin   // setbuf

// Flush prints immediately (useful under launchd)
setbuf(__stdoutp, nil)

// MARK: - Version / CLI
let appVersion: String = "0.2.17"
let args = CommandLine.arguments
let debugEnabled = args.contains("--debug")
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
    // Trackpad: pass through (macOS already smooth)
    static let runLoopMode: CFRunLoopMode = .commonModes

    // Mouse smoothing (velocity model)
    static let pixelsPerLineBase: CGFloat = 28.0   // total distance per line at slow cadence
    static let tauVelocity: CFTimeInterval = 0.22 // seconds; larger = longer glide
    static let timerHz: CFTimeInterval = 240.0    // 120–240 feels great
    static let minVelStop: CGFloat = 6.0          // px/s below which we stop the timer
    static let minAccStop: CGFloat = 0.25         // px remainder threshold to stop

    // Acceleration: boost per quick successive tick
    static let accelGain: CGFloat = 2.0           // 0 = off; 1–3 typical
    static let accelHalfLife: CFTimeInterval = 0.08 // seconds; <=> how “fast” counts as fast

    // Safety clamps
    static let maxEmitPerTick: Int32 = 160        // px per timer tick
    static let maxVelocity: CGFloat = 8000.0      // px/s
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

// MARK: - Wheel animator (velocity-based; mouse only)
final class WheelAnimator {
    private var vel: CGFloat = 0               // pixels per second (signed)
    private var accumulator: CGFloat = 0       // subpixel remainder
    private var lastTime: CFTimeInterval = CACurrentMediaTime()
    private var lastImpulseTime: CFTimeInterval = CACurrentMediaTime()
    private var timer: CFRunLoopTimer?

    func addLines(_ lines: Int32) {
        let now = CACurrentMediaTime()
        let dt = max(1e-4, now - lastImpulseTime)
        lastImpulseTime = now

        // Acceleration boost: faster cadence => larger boost
        let boost = 1.0 + Config.accelGain * CGFloat(exp(-dt / Config.accelHalfLife))

        // Convert desired total distance (px) into an initial velocity impulse (px/s)
        // so that the integral of v(t) matches pixelsPerLineBase * boost for a single line.
        // For first-order decay: integral ≈ v0 * tau  => v0 = pixels / tau
        let pixels = Config.pixelsPerLineBase * boost * CGFloat(lines)
        let vImpulse = pixels / CGFloat(Config.tauVelocity)

        vel += vImpulse
        // Clamp to keep things sane
        vel = max(-Config.maxVelocity, min(Config.maxVelocity, vel))

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

    private func maybeStopTimer() {
        if abs(vel) < Config.minVelStop && abs(accumulator) < Config.minAccStop {
            if let t = timer { CFRunLoopTimerInvalidate(t) }
            timer = nil
            vel = 0
            accumulator = 0
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = max(1e-4, now - lastTime)
        lastTime = now

        // Exponential velocity decay
        let decay = CGFloat(exp(-dt / Config.tauVelocity))
        vel *= decay

        // Integrate displacement
        let move = vel * CGFloat(dt)
        accumulator += move

        var emit = Int32(accumulator.rounded(.towardZero))
        if emit != 0 {
            emit = max(-Config.maxEmitPerTick, min(Config.maxEmitPerTick, emit))
            accumulator -= CGFloat(emit)
            postPixelScroll(emit)
            if debugEnabled { print("anim v:\(Int(vel)) dt:\(String(format: "%.4f", dt)) emit:\(emit) acc:\(String(format: "%.2f", accumulator))") }
        }

        maybeStopTimer()
    }

    func reset() {
        vel = 0
        accumulator = 0
        lastTime = CACurrentMediaTime()
        lastImpulseTime = lastTime
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

    // Pass through native momentum (retain macOS inertia)
    let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
    if momentumPhase != 0 {
        mouseAnimator.reset()
        return Unmanaged.passUnretained(event)
    }

    // Detect device kind
    let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0

    // Reset per gesture (trackpads only)
    let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
    if phase == 1 { // kCGScrollPhaseBegan
        mouseAnimator.reset()
    }

    if isContinuous {
        // TRACKPAD: already smooth; pass through
        return Unmanaged.passUnretained(event)
    } else {
        // MOUSE: consume the line event and animate pixel deltas instead
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

        let lines = Int32(clamping: linesI64)
        if debugEnabled { print("mouse lines: \(lines)") }

        mouseAnimator.addLines(lines)
        // Swallow the original line event (we'll emit smooth pixels over time)
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
