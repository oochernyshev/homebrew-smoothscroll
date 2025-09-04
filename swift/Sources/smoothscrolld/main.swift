//
// smoothscrolld — mouse wheel smoothing with trackpad-style phases (bounce)
// Fractional pixel emission + velocity model with friction & reverse-cancel
//

import Foundation
import CoreGraphics
import QuartzCore
import Darwin    // setbuf

// Flush prints immediately (useful when launched via launchd/Homebrew)
setbuf(__stdoutp, nil)

// MARK: - Version / CLI
let appVersion: String = "0.2.23"
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

// MARK: - Config
struct Config {
    // Core feel
    static let pixelsPerLineBase: CGFloat = 18.0     // px per wheel "line" at slow cadence
    static let tauVelocity: CFTimeInterval = 0.32    // s; larger = longer glide
    static let timerHz: CFTimeInterval = 240.0       // emission rate (≥120 recommended)

    // Acceleration for fast successive ticks
    static let accelGain: CGFloat = 1.2
    static let accelHalfLife: CFTimeInterval = 0.10  // s

    // Momentum handoff (after last user tick)
    static let userToMomentumDelay: CFTimeInterval = 0.050

    // Stability
    static let reverseCancelWindow: CFTimeInterval = 0.080 // s window to hard-cancel on direction flip
    static let reverseCancelBoost: CGFloat = 1.2           // >1 cancels tails faster on flip
    static let staticFriction: CGFloat = 60.0              // px/s² dry friction; higher = stops sooner

    // Stops & clamps
    static let minVelStop: CGFloat = 3.0                   // px/s considered stopped
    static let minAccStop: CGFloat = 0.02                  // px subpixel remainder to stop
    static let maxIntEmitPerTick: Int32 = 160              // safety (legacy int field)
    static let maxFloatEmitPerTick: CGFloat = 50.0         // safety (point/fixed fields)
    static let maxVelocity: CGFloat = 4000.0

    static let maxImpulsePerDetent: CGFloat = 1600.0

    // Run loop mode
    static let runLoopMode: CFRunLoopMode = .commonModes
}

// MARK: - Event tags & phase values
private let kSyntheticTag: Int64 = 0x5343524F4C // "SCROL"

// CG*Phase integer values (avoid type mismatches across SDKs)
private enum ScrollPhase: Int64 { case none = 0, began = 1, changed = 2, ended = 3, cancelled = 4, mayBegin = 5 }
private enum MomentumPhase: Int64 { case none = 0, begin = 1, `continue` = 2, end = 3 }

var gTap: CFMachPort? = nil

// MARK: - Post helper: fractional pixel event with consistent integer fields
@inline(__always)
fileprivate func postPixelScroll(floatDy dyf: CGFloat,
                                intDy iPart: Int32,
                                phase: ScrollPhase = .none,
                                momentum: MomentumPhase = .none) {

    // Clamp for safety
    let dyfClamped = max(-Config.maxFloatEmitPerTick, min(Config.maxFloatEmitPerTick, dyf))
    var iClamped = iPart
    if iClamped > Config.maxIntEmitPerTick { iClamped = Config.maxIntEmitPerTick }
    if iClamped < -Config.maxIntEmitPerTick { iClamped = -Config.maxIntEmitPerTick }

    guard let src = CGEventSource(stateID: .hidSystemState),
          let ev  = CGEvent(scrollWheelEvent2Source: src,
                            units: .pixel,
                            wheelCount: 1,
                            wheel1: iClamped,
                            wheel2: 0,
                            wheel3: 0)
    else { return }

    // Trackpad-style identity (so rubber-banding works)
    ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
    ev.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum.rawValue)

    // Fractional pixel payload (what modern apps use)
    ev.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(dyfClamped))
    ev.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dyfClamped))

    // Legacy integer payload stays consistent over time
    ev.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(iClamped))

    // Tag as synthetic so our tap ignores it
    ev.setIntegerValueField(.eventSourceUserData, value: kSyntheticTag)

    ev.post(tap: .cghidEventTap)
}

// MARK: - Wheel animator (velocity-based, fractional emitter)
final class WheelAnimator {
    private var vel: CGFloat = 0                // px/s (signed)
    private var intAccumulator: CGFloat = 0     // for legacy int field correctness
    private var lastTime: CFTimeInterval = CACurrentMediaTime()
    private var lastImpulseTime: CFTimeInterval = CACurrentMediaTime()
    private var timer: CFRunLoopTimer?

    // Phase state for bounce/rubber-band
    private var needSendBegan = false
    private var inMomentum = false
    private var momentumStarted = false

    func addLines(_ lines: Int32) {
        let now = CACurrentMediaTime()
        let dt  = max(1e-4, now - lastImpulseTime)
        lastImpulseTime = now

        // Acceleration boost for quick cadence
        let boost  = 1.0 + Config.accelGain * CGFloat(exp(-dt / Config.accelHalfLife))
        let pixels = Config.pixelsPerLineBase * boost * CGFloat(lines)

        // Convert desired distance into a velocity impulse: integral ≈ v0 * tau => v0 = pixels / tau
        var impulse = pixels / CGFloat(Config.tauVelocity)
        // Cap how hard a single detent can kick
        if impulse >  Config.maxImpulsePerDetent { impulse =  Config.maxImpulsePerDetent }
        if impulse < -Config.maxImpulsePerDetent { impulse = -Config.maxImpulsePerDetent }

        // Reverse-direction cancellation
        if vel * impulse < 0 {
            if dt < Config.reverseCancelWindow {
                vel = 0
                intAccumulator = 0
            } else {
                impulse *= Config.reverseCancelBoost
            }
        }

        vel = max(-Config.maxVelocity, min(Config.maxVelocity, vel + impulse))

        // New user input => gesture stream; next emit starts with Began
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
        intAccumulator = 0
        needSendBegan = false
        inMomentum = false
        momentumStarted = false
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt  = max(1e-4, now - lastTime)
        lastTime = now

        // Handoff to momentum after a brief quiet period (no new ticks)
        if !inMomentum && !needSendBegan && (now - lastImpulseTime) > Config.userToMomentumDelay {
            inMomentum = true
            momentumStarted = false // send .begin on next emit
        }

        // Exponential decay of velocity
        vel *= CGFloat(exp(-dt / Config.tauVelocity))

        // Dry friction: kills tiny tails quickly
        let friction = Config.staticFriction * CGFloat(dt)
        if abs(vel) > friction {
            vel -= copysign(friction, vel)
        } else {
            vel = 0
        }

        // Fractional displacement this frame
        let move = vel * CGFloat(dt)
        if move != 0 {
            // Keep legacy integer field correct across frames
            intAccumulator += move
            var iEmit = Int32(intAccumulator.rounded(.towardZero))
            if iEmit >  Config.maxIntEmitPerTick { iEmit =  Config.maxIntEmitPerTick }
            if iEmit < -Config.maxIntEmitPerTick { iEmit = -Config.maxIntEmitPerTick }
            intAccumulator -= CGFloat(iEmit)

            if inMomentum {
                let mom: MomentumPhase = momentumStarted ? .continue : .begin
                momentumStarted = true
                postPixelScroll(floatDy: move, intDy: iEmit, phase: .none, momentum: mom)
            } else {
                if needSendBegan {
                    postPixelScroll(floatDy: move, intDy: iEmit, phase: .began, momentum: .none)
                    needSendBegan = false
                } else {
                    postPixelScroll(floatDy: move, intDy: iEmit, phase: .changed, momentum: .none)
                }
            }

            if debugEnabled {
                print(String(format: "emit f:%.3f i:%d vel:%d acc:%.3f inMom:%d",
                             move, iEmit, Int(vel), intAccumulator, inMomentum ? 1 : 0))
            }
        }

        // Stop conditions & proper end markers
        if abs(vel) < Config.minVelStop && abs(intAccumulator) < Config.minAccStop {
            if inMomentum {
                postPixelScroll(floatDy: 0, intDy: 0, phase: .none, momentum: .end)
            } else if !needSendBegan {
                postPixelScroll(floatDy: 0, intDy: 0, phase: .ended, momentum: .none)
            } else {
                postPixelScroll(floatDy: 0, intDy: 0, phase: .ended, momentum: .none)
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
        // MOUSE: consume line event and animate velocity instead
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
