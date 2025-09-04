//
// smoothscrolld — mouse wheel smoothing with trackpad-style phases (bounce)
//

import Foundation
import CoreGraphics
import QuartzCore
import Darwin    // setbuf

// Flush prints immediately (useful when launched via launchd/Homebrew)
setbuf(__stdoutp, nil)

// MARK: - Version / CLI
let appVersion: String = "0.2.18"
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
    // Mouse smoothing (velocity model)
    static let pixelsPerLineBase: CGFloat = 28.0    // total px per wheel "line" at slow cadence
    static let tauVelocity: CFTimeInterval = 0.28   // seconds; larger = longer glide
    static let timerHz: CFTimeInterval = 240.0      // emission rate (120–240 is good)
    static let minVelStop: CGFloat = 6.0            // px/s threshold to stop anim
    static let minAccStop: CGFloat = 0.25           // px remainder threshold to stop

    // Acceleration (fast successive ticks travel farther)
    static let accelGain: CGFloat = 2.2             // 0=off, 1–3 typical
    static let accelHalfLife: CFTimeInterval = 0.10 // seconds; how “fast” counts as fast

    // Safety clamps
    static let maxEmitPerTick: Int32 = 160          // px per timer tick
    static let maxVelocity: CGFloat = 8000.0        // px/s

    // Run loop mode
    static let runLoopMode: CFRunLoopMode = .commonModes
}

// MARK: - Event tags & phase values
private let kSyntheticTag: Int64 = 0x5343524F4C // "SCROL"

// CG*Phase integer values (avoid type mismatches across SDKs)
private enum ScrollPhase: Int64 { case none = 0, began = 1, changed = 2, ended = 3, cancelled = 4, mayBegin = 5 }
private enum MomentumPhase: Int64 { case none = 0, begin = 1, `continue` = 2, end = 3 }

var gTap: CFMachPort? = nil

// MARK: - Posting helper (pixel scroll with phases)
@inline(__always)
fileprivate func postPixelScroll(_ dy: Int32,
                     phase: ScrollPhase = .none,
                     momentum: MomentumPhase = .none) {
    guard let src = CGEventSource(stateID: .hidSystemState),
          let ev = CGEvent(scrollWheelEvent2Source: src,
                           units: .pixel,
                           wheelCount: 1,
                           wheel1: dy,
                           wheel2: 0,
                           wheel3: 0)
    else { return }

    // Make it look like a gesture (trackpad-style) so apps enable rubber-banding.
    ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
    ev.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum.rawValue)

    // Tag as synthetic so our tap ignores it
    ev.setIntegerValueField(.eventSourceUserData, value: kSyntheticTag)

    ev.post(tap: .cghidEventTap)
}

// MARK: - Wheel animator (velocity-based; mouse only)
final class WheelAnimator {
    private var vel: CGFloat = 0               // pixels per second (signed)
    private var accumulator: CGFloat = 0       // subpixel remainder
    private var lastTime: CFTimeInterval = CACurrentMediaTime()
    private var lastImpulseTime: CFTimeInterval = CACurrentMediaTime()
    private var timer: CFRunLoopTimer?

    // Phase state for bounce/rubber-band
    private var needSendBegan = false
    private var inMomentum = false
    private var momentumStarted = false

    // Delay after last user tick before switching to "momentum"
    private let userToMomentumDelay: CFTimeInterval = 0.050

    func addLines(_ lines: Int32) {
        let now = CACurrentMediaTime()
        let dt = max(1e-4, now - lastImpulseTime)
        lastImpulseTime = now

        // Acceleration boost: faster cadence => larger boost
        let boost = 1.0 + Config.accelGain * CGFloat(exp(-dt / Config.accelHalfLife))

        // Convert desired total distance (px) into a velocity impulse (px/s)
        // For first-order decay: integral ≈ v0 * tau => v0 = pixels / tau
        let pixels = Config.pixelsPerLineBase * boost * CGFloat(lines)
        let vImpulse = pixels / CGFloat(Config.tauVelocity)

        vel = max(-Config.maxVelocity, min(Config.maxVelocity, vel + vImpulse))

        // New user input => gesture phase (not momentum), and next emit should start with Began
        needSendBegan = true
        inMomentum = false
        momentumStarted = false

        startTimerIfNeeded()
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        lastTime = CACurrentMediaTime()
        let interval = 1.0 / Config.timerHz
        timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + interval,
            interval, 0, 0
        ) { [weak self] _ in
            self?.tick()
        }
        if let t = timer {
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, Config.runLoopMode)
        }
    }

    private func stopTimer() {
        if let t = timer { CFRunLoopTimerInvalidate(t) }
        timer = nil
        vel = 0
        accumulator = 0
        needSendBegan = false
        inMomentum = false
        momentumStarted = false
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = max(1e-4, now - lastTime)
        lastTime = now

        // Switch to momentum if user hasn't ticked recently
        if !inMomentum && (now - lastImpulseTime) > userToMomentumDelay && !needSendBegan {
            inMomentum = true
            momentumStarted = false // will send .begin on next emit
        }

        // Exponential velocity decay
        vel *= CGFloat(exp(-dt / Config.tauVelocity))

        // Integrate displacement
        accumulator += vel * CGFloat(dt)

        // Emit whole pixels this tick
        var emit = Int32(accumulator.rounded(.towardZero))
        if emit != 0 {
            emit = max(-Config.maxEmitPerTick, min(Config.maxEmitPerTick, emit))
            accumulator -= CGFloat(emit)

            if inMomentum {
                // Momentum stream
                let mom: MomentumPhase = momentumStarted ? .continue : .begin
                momentumStarted = true
                postPixelScroll(emit, phase: .none, momentum: mom)
            } else {
                // Gesture stream
                if needSendBegan {
                    postPixelScroll(emit, phase: .began, momentum: .none)
                    needSendBegan = false
                } else {
                    postPixelScroll(emit, phase: .changed, momentum: .none)
                }
            }

            if debugEnabled {
                print("emit \(emit)  v:\(Int(vel))  acc:\(String(format: "%.2f", accumulator))  inMomentum:\(inMomentum)")
            }
        }

        // Stop conditions & proper end markers
        if abs(vel) < Config.minVelStop && abs(accumulator) < Config.minAccStop {
            if inMomentum {
                postPixelScroll(0, phase: .none, momentum: .end)
            } else if !needSendBegan {
                postPixelScroll(0, phase: .ended, momentum: .none)
            } else {
                // Edge case: Began was requested but no pixels were emitted — still close.
                postPixelScroll(0, phase: .ended, momentum: .none)
            }
            stopTimer()
        }
    }

    func reset() { stopTimer() }
}

let mouseAnimator = WheelAnimator()

// MARK: - Event Callback
func eventCallback(proxy: CGEventTapProxy,
                   type: CGEventType,
                   event: CGEvent,
                   refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {

    // If the system disabled our tap, re-enable and pass event through
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = gTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    guard type == .scrollWheel else {
        return Unmanaged.passUnretained(event)
    }

    // Ignore our own synthetic events
    if event.getIntegerValueField(.eventSourceUserData) == kSyntheticTag {
        return Unmanaged.passUnretained(event)
    }

    // Pass through native momentum (retain macOS inertia)
    let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
    if momentumPhase != 0 {
        mouseAnimator.reset()
        return Unmanaged.passUnretained(event)
    }

    // Trackpad vs mouse
    let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0

    // Trackpad gesture phase (used to reset animator between gestures)
    let phaseI64 = event.getIntegerValueField(.scrollWheelEventScrollPhase)
    if phaseI64 == ScrollPhase.began.rawValue {
        mouseAnimator.reset()
    }

    if isContinuous {
        // TRACKPAD: already smooth; pass through untouched
        return Unmanaged.passUnretained(event)
    } else {
        // MOUSE: consume line event and animate pixel deltas instead
        var linesI64 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        if linesI64 == 0 {
            // Fallbacks (rare on mice)
            let dyFixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            let dyPoint = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let dy = (dyFixed != 0.0) ? dyFixed : dyPoint
            linesI64 = Int64(dy.rounded())
        }
        if linesI64 == 0 {
            // Nothing to do; pass through just in case
            return Unmanaged.passUnretained(event)
        }

        let lines = Int32(clamping: linesI64)
        if debugEnabled { print("mouse lines: \(lines) (raw64: \(linesI64))") }

        mouseAnimator.addLines(lines)
        // Swallow the original line event (we'll emit smooth pixels over time)
        return nil
    }
}

// MARK: - Event Tap Setup
let mask: CGEventMask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
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
