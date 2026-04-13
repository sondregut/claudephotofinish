import Foundation
import CoreMedia
import CoreVideo
import UIKit
import ImageIO
import Accelerate

// MARK: - Picker Mode
//
// Controls how detectionY is chosen from the gate-band mask.
// The fire condition (local_support) always uses the full-blob longest run;
// only the Y pick changes. See detector_hypotheses.md §12.5.
enum PickerMode: String, CaseIterable, Equatable {
    case longestRun    = "Longest"  // current: midpoint of densest vertical run (whole blob)
    case topThird      = "Top ⅓"   // midpoint of densest run in top ⅓ of blob (relative, hypothesis A)
    case absoluteFloor = "Floor"    // densest run above a fixed frame-Y floor; no fire if nothing above floor (hypothesis B)
}

// MARK: - Detection Result

struct DetectionResult {
    let crossingTime: TimeInterval
    let frameTimestamp: CMTime
    let interpolationFraction: Double   // 0..1 — how far between N-1 and N the crossing occurred
    let dBefore: Float                  // pixels from old leading edge to gate
    let dAfter: Float                   // pixels from gate to new leading edge
    let movingLeftToRight: Bool
    let gateY: Int                      // §19 torsoGateY — drives timing, interpolation, and display
    let rawGateY: Int                   // §19 analyzeGate picker output — debug only
    let triggerHRun: Int                // §19 hRun at torsoGateY
    let triggerBandRows: Int            // §19 rows in the 7-row window meeting torsoMinHRun
    let componentBounds: CGRect
    let thumbnailData: Data?
    let isLandscapeBuffer: Bool
}

// MARK: - Internal Types

private struct Component {
    var minX: Int = Int.max
    var maxX: Int = 0
    var minY: Int = Int.max
    var maxY: Int = 0
    var area: Int = 0

    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
}

private struct GateAnalysis {
    var hasQualifyingSlice: Bool
    var detectionY: Int
    var maxVerticalRun: Int
    // Start index (into the columns array) of the 3-column sliding window that
    // produced the winning score. -1 when no window was scored.
    var winWindowStart: Int
}

// MARK: - Detection Engine

final class DetectionEngine {

    // Processing resolution (portrait: width < height)
    let processWidth  = 180
    let processHeight = 320
    private var scaleX = 4             // horizontal downsample factor, computed from actual frame
    private var scaleY = 4             // vertical downsample factor, computed from actual frame
    private var lastFullW = 0          // track frame size changes (camera switch)

    // Buffers
    private var bufferA: [UInt8]
    private var bufferB: [UInt8]
    private var usingA = true
    private var diffBuf: [UInt8]
    private var maskBuf: [UInt8]
    private var labels:  [Int32]

    // Previous-frame bookkeeping
    private var hasPrevious = false
    private var previousTimestamp: CMTime = .zero
    private var previousExposureDuration: CMTime?

    // Thresholds (from spec)
    private let diffThreshold: UInt8    = 15
    // Lowered 2026-04-11 from 0.33 → 0.30 to match Photo Finish's documented
    // global size behavior (§19 torso-gate fix). The Stage 2 torso gate below
    // carries the burden of rejecting non-body blobs, so the global size
    // prefilter can afford to be slightly more permissive.
    private let heightFraction: Float   = 0.30
    private let widthFraction:  Float   = 0.08
    // Reverted 2026-04-07 from 0.15 → 0.25 after the post-Test-N cross-tab
    // in test_runs_our_detector.md showed that 5 of 7 Test N elbow leakers
    // have run/h < 25% while every Tests F/G/H body crossing has run/h ≥ 25%.
    // The 0.15 value (commit 8003aca "Lower detection thresholds for earlier
    // firing") was opening the leak path for most elbow swipes.
    private let localSupportFraction: Float = 0.25
    private let minFillRatio: Float = 0.20       // reject sparse blobs (hand swipes)
    private let maxAspectRatio: Float = 1.2      // reject wide-flat blobs (legs/hand swipes)
    private let spikeRatioThreshold: Float = 1.5 // §15: arm-spike rejection — if hRun at detY > median × this, re-pick
    private let warmupFrames: Int = 10           // skip early frames while auto-exposure settles

    // §19 Torso-gate constants (Test X fix, 2026-04-11). The gate fire now
    // requires a torso-like band at the gate column — not just any vertical
    // run of motion. These replace the old post-hoc frameBiasCap clamp which
    // moved the visible marker but never moved the fire frame.
    private let torsoMinHRun: Int = 18
    private let torsoBandRows: Int = 5
    private let torsoWindowRows: Int = 7
    // §19 search ceiling: fraction used for BOTH the frame-relative and
    // blob-relative upper-portion ceilings in `pickTorsoGateRow`. The
    // effective searchMaxY is `max(frameCeiling, blobCeiling)` so tall
    // top-of-frame blobs (Test W sprinter) keep their old scan range
    // while lower-frame blobs (Test Y/Z hand swipe) unlock the upper
    // portion of the blob itself. Matches PF's model per 2026-04-11
    // user feedback: "fires higher up on the blob, avoiding legs."
    private let torsoSearchMaxFrac: Float = 0.55

    // §19 Full-frame flash guard: reject blobs that cover nearly the entire
    // frame with high fill. Photo Finish has no such pathology because its
    // exposure control differs; for us this catches the Test X #14 "auto-
    // exposure snap" pattern where every pixel changes at once and the
    // connected component becomes the whole frame.
    private let flashGuardCoverage: Float = 0.55   // blob area / frame area
    private let flashGuardFill: Float = 0.70       // blob area / (w*h)
    private let flashGuardWFrac: Float = 0.80      // blob width / frame width
    private let flashGuardHFrac: Float = 0.80      // blob height / frame height

    // §12.5 A/B picker toggle — change at runtime from the tuning panel
    var pickerMode: PickerMode = .longestRun
    var absolutePickerFloor: Int = 160           // only used when pickerMode == .absoluteFloor

    // Gate
    var gateColumn: Int { processWidth / 2 }
    private let gateBandHalf: Int = 2

    // Session state
    private(set) var isActive = false
    var isFrontCamera = false
    private var sessionStart: CMTime?
    private var lastDetectionElapsed: TimeInterval?
    private var lastDetectionRealElapsed: TimeInterval?   // actual frame time, for cooldown
    private let cooldown: TimeInterval = 0.5
    private var gateOccupied = false   // after detection, wait for gate to clear before re-arming

    // Logging
    private var lastRejectReason = ""
    private var frameIndex = 0

    // Buildup tracking: how many consecutive frames had a gate-intersecting,
    // size-qualified blob before detection fires. Helps discriminate sudden
    // spikes (hand swipes) from gradual buildup (body crossings).
    private var gateBuildup = 0

    // §17.4 H2 diagnostic: ring buffer of max candidate effectiveH for the last
    // 2 frames (index 0 = frame-2, index 1 = frame-1). Combined with the current
    // frame's max we compute a 3-frame min for LS_COUNTERFACT logging. Pure
    // instrumentation — does not affect detector behavior.
    private var candidateHHistory: [Int] = [0, 0]
    private var currentFrameMaxCandidateH: Int = 0

    // MARK: Init

    init() {
        let count = processWidth * processHeight
        bufferA = [UInt8](repeating: 0, count: count)
        bufferB = [UInt8](repeating: 0, count: count)
        diffBuf = [UInt8](repeating: 0, count: count)
        maskBuf = [UInt8](repeating: 0, count: count)
        labels  = [Int32](repeating: 0, count: count)
    }

    // MARK: Control

    func start(at timestamp: CMTime? = nil) {
        isActive = true
        sessionStart = timestamp
        lastDetectionElapsed = nil
        lastDetectionRealElapsed = nil
        gateOccupied = false
        gateBuildup = 0
        candidateHHistory = [0, 0]
        currentFrameMaxCandidateH = 0
        hasPrevious = false
        lastRejectReason = ""
        frameIndex = 0
        lastFullW = 0
        slog("[ENGINE] started, process=\(processWidth)x\(processHeight)")
        logEngineConfig()
    }

    /// Emit the full detection-engine configuration as a single grep-friendly
    /// line. Fires on every `start()` so each test run in the log buffer is
    /// self-describing — you can tell from the log alone which picker mode,
    /// thresholds, and geometry constants were in effect.
    private func logEngineConfig() {
        let pickerDesc: String
        switch pickerMode {
        case .longestRun:    pickerDesc = "longestRun"
        case .topThird:      pickerDesc = "topThird"
        case .absoluteFloor: pickerDesc = "floor\(absolutePickerFloor)"
        }
        slog(String(format:
            "[ENGINE_CONFIG] picker=%@ cam=%@ process=%dx%d gate=col%d±%d diffThresh=%d hFrac=%.2f wFrac=%.2f localSupport=%.2f minFill=%.2f maxAspect=%.1f torsoMinHRun=%d torsoBand=%d/%d torsoMaxFrac=%.2f spikeRatio=%.1f warmup=%d cooldown=%.2fs",
            pickerDesc, isFrontCamera ? "front" : "back",
            processWidth, processHeight, gateColumn, gateBandHalf,
            Int(diffThreshold), heightFraction, widthFraction,
            localSupportFraction, minFillRatio, maxAspectRatio,
            torsoMinHRun, torsoBandRows, torsoWindowRows, torsoSearchMaxFrac,
            spikeRatioThreshold, warmupFrames, cooldown
        ))
    }

    func stop() {
        isActive = false
    }

    /// Re-arm the warmup counter so the next N frames are skipped.
    /// Called after a camera-session interruption (background/foreground)
    /// to suppress the exposure-snap false positive.
    func resetWarmup() {
        frameIndex = 0
        hasPrevious = false
        slog("[ENGINE] warmup reset (post-interruption)")
    }

    func reset() {
        stop()
        sessionStart = nil
        lastDetectionElapsed = nil
        lastDetectionRealElapsed = nil
        gateOccupied = false
        hasPrevious = false
        frameIndex = 0
        lastFullW = 0
        candidateHHistory = [0, 0]
        currentFrameMaxCandidateH = 0
    }

    // MARK: Main Processing

    func processFrame(
        _ pixelBuffer: CVPixelBuffer,
        timestamp: CMTime,
        exposureDuration: CMTime?,
        iso: Float?
    ) -> DetectionResult? {
        guard isActive else { return nil }

        if sessionStart == nil { sessionStart = timestamp }
        frameIndex += 1

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else { return nil }
        let fullW = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let fullH = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bpr   = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }

        // Y plane may arrive landscape despite videoRotationAngle=90
        let isLandscape = fullW > fullH

        // Recompute scale whenever frame dimensions change (startup, camera switch)
        if fullW != lastFullW {
            lastFullW = fullW
            let srcW = isLandscape ? fullH : fullW
            let srcH = isLandscape ? fullW : fullH
            scaleX = max(srcW / processWidth, 1)
            scaleY = max(srcH / processHeight, 1)
            hasPrevious = false  // don't diff across camera switches
            slog("[INIT] buffer=\(fullW)x\(fullH) bpr=\(bpr) landscape=\(isLandscape) process=\(processWidth)x\(processHeight) scaleX=\(scaleX) scaleY=\(scaleY)")
        }

        // Extract grayscale into current buffer
        let W = processWidth, H = processHeight
        if usingA {
            extractGray(base: base, fullW: fullW, fullH: fullH, bpr: bpr,
                        w: W, h: H, transpose: isLandscape, into: &bufferA)
        } else {
            extractGray(base: base, fullW: fullW, fullH: fullH, bpr: bpr,
                        w: W, h: H, transpose: isLandscape, into: &bufferB)
        }

        defer {
            usingA.toggle()
            previousTimestamp = timestamp
            previousExposureDuration = exposureDuration
            hasPrevious = true
        }

        guard hasPrevious else { return nil }

        // Skip detection during warmup (auto-exposure settling)
        if frameIndex <= warmupFrames { return nil }

        // Cooldown — compare against real frame time of last detection, not
        // interpolated crossing time.  Frame drops can create a large real-time gap
        // that makes the interpolated-time cooldown pass for the same object.
        let now = CMTimeGetSeconds(timestamp)
        let start = CMTimeGetSeconds(sessionStart!)
        let elapsed = now - start
        if let lastReal = lastDetectionRealElapsed, (elapsed - lastReal) < cooldown { return nil }

        let count = W * H

        // 1. Frame diff + threshold (fused, unsafe pointers to skip debug bounds checks)
        let thresh = diffThreshold
        let curArr = usingA ? bufferA : bufferB
        let prevArr = usingA ? bufferB : bufferA
        curArr.withUnsafeBufferPointer { cur in
            prevArr.withUnsafeBufferPointer { prev in
                diffBuf.withUnsafeMutableBufferPointer { diff in
                    maskBuf.withUnsafeMutableBufferPointer { mask in
                        let cp = cur.baseAddress!, pp = prev.baseAddress!
                        let dp = diff.baseAddress!, mp = mask.baseAddress!
                        for i in 0..<count {
                            let d = Int16(cp[i]) - Int16(pp[i])
                            let abs_d = d < 0 ? UInt8(-d) : UInt8(d)
                            dp[i] = abs_d
                            mp[i] = abs_d >= thresh ? 1 : 0
                        }
                    }
                }
            }
        }

        // 2. Connected components
        let components = findComponents()

        // 3. Gate detection
        let minH = Int(Float(H) * heightFraction)
        let minW = Int(Float(W) * widthFraction)
        let gMin = max(gateColumn - gateBandHalf, 0)
        let gMax = min(gateColumn + gateBandHalf, W - 1)

        // §19 candidate tuple carries both the raw analyzeGate picker output
        // (debug-only) and the torso-confirmed row that drives timing + display.
        var best: (
            comp: Component,
            rawDetY: Int,
            torsoY: Int,
            run: Int,
            winStart: Int,
            torsoHRun: Int,
            torsoBand: Int
        )?
        var candidateCount = 0
        var limbWaitCount = 0
        let frameAbsMin = Int(Float(H) * minGateHeightFraction)
        var anyBlobAtGate = false
        currentFrameMaxCandidateH = 0

        for comp in components {
            if comp.height < minH {
                logReject("height", detail: "\(comp.height)/\(minH)")
                continue
            }
            if comp.width < minW {
                logReject("width", detail: "\(comp.width)/\(minW)")
                continue
            }
            let fillRatio = Float(comp.area) / Float(comp.width * comp.height)
            var trimmedHeight: Int? = nil
            if fillRatio < minFillRatio {
                // §15: arm inflation drops fill — try tightFill excluding spike rows
                let (tightFill, trimmedH) = computeTightFill(comp: comp)
                if tightFill < minFillRatio {
                    logReject("fill_ratio", detail: String(format: "%.2f/%.2f area=%d tightFill=%.2f", fillRatio, minFillRatio, comp.area, tightFill))
                    continue
                }
                // Blob rescued by tightFill — use trimmedH for local_support need
                trimmedHeight = trimmedH
                slog(String(format: "[FILL_RESCUE] frame=%d fill=%.2f tightFill=%.2f trimmedH=%d", frameIndex, fillRatio, tightFill, trimmedH))
            }
            if comp.width > Int(maxAspectRatio * Float(comp.height)) {
                logReject("aspect_ratio", detail: String(format: "w=%d h=%d ratio=%.1f", comp.width, comp.height, Float(comp.width) / Float(comp.height)))
                continue
            }
            guard comp.maxX >= gMin, comp.minX <= gMax else {
                logReject("no_gate_intersection")
                continue
            }

            // §19 Full-frame flash guard (Test X #14 failure mode).
            // A global auto-exposure snap creates a connected component that
            // covers nearly the whole frame with uniformly high fill. Without
            // this prefilter, the torso gate below would over-qualify it
            // because every row hits hRun ≈ W.
            let frameArea = Float(W * H)
            let coverage = Float(comp.area) / frameArea
            let wFrac = Float(comp.width) / Float(W)
            let hFrac = Float(comp.height) / Float(H)
            if coverage > flashGuardCoverage
                && fillRatio > flashGuardFill
                && wFrac > flashGuardWFrac
                && hFrac > flashGuardHFrac {
                logReject("full_frame_flash",
                          detail: String(format: "cov=%.2f fill=%.2f wFrac=%.2f hFrac=%.2f",
                                         coverage, fillRatio, wFrac, hFrac))
                continue
            }

            let effectiveH = trimmedHeight ?? comp.height
            if effectiveH > currentFrameMaxCandidateH { currentFrameMaxCandidateH = effectiveH }
            guard let analysis = analyzeGate(comp: comp, gMin: gMin, gMax: gMax) else {
                continue
            }
            anyBlobAtGate = true
            guard analysis.hasQualifyingSlice else {
                // §18 H2 fix: reject log uses same floor-only rule as analyzeGate
                let need = max(3, frameAbsMin)

                // §17.4 H2 counterfactual instrumentation: log what `need`
                // would have been under two alternative rules so we can
                // pre-validate a fix offline without changing behavior.
                //   - need_current: current rule (h × 0.25, floored at 25)
                //   - need_min3   : min effectiveH over last 3 frames × 0.25
                //   - need_floor  : floor only (25), no height scaling
                var min_h = effectiveH
                if candidateHHistory[0] > 0 { min_h = min(min_h, candidateHHistory[0]) }
                if candidateHHistory[1] > 0 { min_h = min(min_h, candidateHHistory[1]) }
                let need_min3 = max(3, Int(Float(min_h) * localSupportFraction), frameAbsMin)
                let need_floor = max(3, frameAbsMin)
                let run = analysis.maxVerticalRun
                let pass_current = run >= need      ? "Y" : "N"
                let pass_min3    = run >= need_min3 ? "Y" : "N"
                let pass_floor   = run >= need_floor ? "Y" : "N"
                slog(String(format:
                    "[LS_COUNTERFACT] frame=%d run=%d h=%d min_h3=%d need_current=%d pass=%@ need_min3=%d pass=%@ need_floor=%d pass=%@",
                    frameIndex, run, effectiveH, min_h,
                    need, pass_current,
                    need_min3, pass_min3,
                    need_floor, pass_floor))

                logReject("local_support",
                          detail: "run=\(run) need=\(need)")
                continue
            }

            // §19 Stage 2: torso-row confirmation. Stage 1 has told us
            // *something* is moving at the gate column; Stage 2 decides if
            // what's there is actually a torso. If not, refuse to fire —
            // do not start cooldown, do not mark gateOccupied. The next
            // frame will have another chance once the torso arrives.
            guard let torso = pickTorsoGateRow(comp: comp) else {
                limbWaitCount += 1
                // Must mirror `pickTorsoGateRow`'s searchMaxY formula
                // (blob-relative ∪ frame-relative) so LIMB_WAIT logs
                // reflect the actual scan range. Keeping the old
                // frame-only formula here would make every post-§19
                // diagnostic log lie about where we searched.
                let blobHeight = comp.maxY - comp.minY + 1
                let blobUpperCeiling = comp.minY + Int(Float(blobHeight) * torsoSearchMaxFrac)
                let frameUpperCeiling = Int(Float(H) * torsoSearchMaxFrac)
                let searchMax = min(comp.maxY, max(frameUpperCeiling, blobUpperCeiling))
                slog(String(format:
                    "[LIMB_WAIT] frame=%d blob=%dx%d rawDetY=%d run=%d searchMaxY=%d reason=no_torso_band",
                    frameIndex, comp.width, comp.height,
                    analysis.detectionY, analysis.maxVerticalRun, searchMax))
                continue
            }

            candidateCount += 1
            if best == nil || comp.area > best!.comp.area {
                best = (
                    comp: comp,
                    rawDetY: analysis.detectionY,
                    torsoY: torso.y,
                    run: analysis.maxVerticalRun,
                    winStart: analysis.winWindowStart,
                    torsoHRun: torso.hRun,
                    torsoBand: torso.bandRows
                )
            }
        }

        // §17.4 H2 diagnostic: shift ring buffer forward one frame.
        // Slot 0 drops off, slot 1 becomes slot 0, current frame becomes slot 1.
        candidateHHistory[0] = candidateHHistory[1]
        candidateHHistory[1] = currentFrameMaxCandidateH

        // Update buildup counter: increment if any blob reached gate analysis,
        // reset if no blob was at the gate at all.
        if anyBlobAtGate {
            gateBuildup += 1
        } else {
            gateBuildup = 0
        }

        guard let candidate = best else {
            // No qualifying blob at gate — clear the occupied flag so next real
            // crossing can fire immediately once the gate is clean.
            if gateOccupied { gateOccupied = false }
            return nil
        }

        // Gate-clear guard: after a detection, require at least one frame where
        // no qualifying blob occupies the gate before re-arming. This prevents
        // double-triggers when frame drops cause the time-based cooldown to expire
        // while the same person is still crossing.
        if gateOccupied {
            logReject("gate_occupied")
            return nil
        }

        // §19 Torso-confirmed detY. The Stage 2 picker chose a row with a
        // torso-like horizontal run, by construction not an arm spike, so we
        // use it directly for timing, interpolation, and the displayed marker.
        // rawDetY (analyzeGate's picker output) stays on the DETECT log as a
        // debug comparison but never influences the fire.
        let torsoDetY = candidate.torsoY
        let rawDetY = candidate.rawDetY

        // Keep adjustForArmSpike as a *diagnostic* — it builds the HRUN_PROFILE
        // string we still want in logs. The adjustedDetY value is discarded
        // because the torso row is already spike-free.
        let spikeProfile = adjustForArmSpike(detY: torsoDetY, comp: candidate.comp)

        // Log all size-qualified components for diagnostics
        let qualComps = components.filter { $0.height >= minH && $0.width >= minW }
        for (i, comp) in qualComps.enumerated() {
            let atGate = comp.maxX >= gMin && comp.minX <= gMax
            let tag = comp.area == candidate.comp.area ? ">>>" : "   "
            slog(String(format: "[COMP] %@ #%d %dx%d x=%d..%d y=%d..%d area=%d gate=%@",
                         tag, i, comp.width, comp.height, comp.minX, comp.maxX, comp.minY, comp.maxY, comp.area, atGate ? "YES" : "no"))
        }

        // §19 Body-part suppression is SKIPPED for torso-confirmed candidates.
        // Stage 2 torso gating has already verified this blob has a stable
        // torso band at the gate column; a larger approaching component off
        // to the side is almost always (a) the same person's following limb,
        // or (b) a second runner who will trigger their own detection when
        // they reach the gate. Suppressing at this point just drops good
        // crossings — the Test X logs show exactly this pattern. The scan
        // is still performed for a diagnostic [BPS_SKIP] log line so we can
        // tell when this rule would have fired historically.
        let approachZone = Int(Float(W) * 0.20) // within 20% of frame width
        for comp in components {
            guard comp.height >= minH, comp.width >= minW else { continue }
            guard comp.area > candidate.comp.area else { continue }
            guard comp.maxX < gMin || comp.minX > gMax else { continue }
            let distToGate = comp.maxX < gMin ? (gMin - comp.maxX) : (comp.minX - gMax)
            if distToGate <= approachZone {
                slog(String(format:
                    "[BPS_SKIP] frame=%d gate_area=%d approaching_area=%d dist=%d (torso-confirmed — not suppressing)",
                    frameIndex, candidate.comp.area, comp.area, distToGate))
            }
        }

        // 6. Position-based interpolation (spec 7.1)
        // At the detection row (torsoDetY), find the continuous horizontal run
        // of mask pixels containing the gate. This is the leading-edge strip —
        // its extent on each side of the gate gives the distances for
        // interpolation. §19: uses torsoDetY so timing and display agree.
        let detRow = torsoDetY
        let prevSec = CMTimeGetSeconds(previousTimestamp)
        let dt = now - prevSec

        var runLeftX = gateColumn
        var runRightX = gateColumn

        // Scan left from gate
        var x = gateColumn - 1
        while x >= 0 && maskBuf[detRow * W + x] != 0 { runLeftX = x; x -= 1 }
        // Scan right from gate
        x = gateColumn + 1
        while x < W && maskBuf[detRow * W + x] != 0 { runRightX = x; x += 1 }

        // Determine motion direction from component centroid relative to gate.
        // The bulk of the body is on the approaching side.
        let compCenterX = (candidate.comp.minX + candidate.comp.maxX) / 2
        let movingLeftToRight = compCenterX <= gateColumn

        // In the diff strip at detRow, one end is the old leading-edge position (frame N-1)
        // and the other is the new leading-edge position (frame N).
        // dBefore = distance from old leading edge to gate (how far it still had to go)
        // dAfter  = distance from gate to new leading edge (how far past the gate it went)
        let dBefore: Float
        let dAfter: Float
        if movingLeftToRight {
            dBefore = Float(gateColumn - runLeftX)
            dAfter  = Float(runRightX - gateColumn)
        } else {
            dBefore = Float(runRightX - gateColumn)
            dAfter  = Float(gateColumn - runLeftX)
        }
        let stripWidth = dBefore + dAfter

        var crossingTime: TimeInterval
        let fraction = stripWidth > 0 ? Double(dBefore / stripWidth) : 0.5
        crossingTime = prevSec + fraction * dt - start

        // Low-light exposure correction (spec 7.3)
        if let exp = exposureDuration ?? previousExposureDuration {
            let expSec = CMTimeGetSeconds(exp)
            if expSec > 0.002 { crossingTime += 0.75 * expSec }
        }

        lastDetectionElapsed = crossingTime
        lastDetectionRealElapsed = elapsed
        gateOccupied = true
        lastRejectReason = ""
        // Capture buildup before reset — used in DETECT log and DETECT_DIAG
        let buildupAtDetection = gateBuildup

        let c = candidate.comp
        let hR = Float(c.height) / Float(H)
        let wR = Float(c.width) / Float(W)

        let fR = Float(c.area) / Float(c.width * c.height)
        let dir = movingLeftToRight ? "L>R" : "R>L"
        // Horizontal mask width at detY — physical thickness of the object as it
        // crosses the gate. Theorized discriminator between torso (~30-60px) and
        // elbow/arm (~10-20px). See test_runs_our_detector.md Test N.
        let hRun = runRightX - runLeftX + 1
        // Shutter + ISO on the frame that triggered the detection. These drive
        // motion-blur width at the leading edge and are the primary suspects for
        // the "detY lands on the densest stripe, not the leading edge" bias —
        // see test_runs_our_detector.md Test B/C.
        let expMs = exposureDuration.map { CMTimeGetSeconds($0) * 1000 } ?? -1
        let isoVal = iso ?? -1
        let pickerTag: String
        switch pickerMode {
        case .longestRun:    pickerTag = ""
        case .topThird:      pickerTag = " picker=topThird"
        case .absoluteFloor: pickerTag = " picker=floor\(absolutePickerFloor)"
        }
        // §19: detY is now torsoDetY, rawDetY is the analyzeGate picker output,
        // torsoHRun/torsoBand record what made Stage 2 accept this row.
        slog(String(format: "[DETECT] blob=%dx%d hR=%.2f wR=%.2f fill=%.2f run=%d hRun=%d interp=%.0f/%.0f dir=%@ cands=%d limbWait=%d area=%d x=%d..%d detY=%d rawDetY=%d torsoHRun=%d torsoBand=%d/%d frame=%d time=%.3f exp=%.2fms iso=%.0f buildup=%d%@",
                     c.width, c.height, hR, wR, fR, candidate.run, hRun, dBefore, dAfter, dir,
                     candidateCount, limbWaitCount, c.area, c.minX, c.maxX,
                     torsoDetY, rawDetY,
                     candidate.torsoHRun, candidate.torsoBand, torsoWindowRows,
                     frameIndex, crossingTime, expMs, isoVal, buildupAtDetection, pickerTag))

        // §15 instrumentation: per-row hRun profile at the gate column.
        // §19: the profile is now anchored on torsoDetY (the row actually used
        // for timing) rather than the discarded raw picker output.
        if !spikeProfile.profile.isEmpty {
            slog("[HRUN_PROFILE] frame=\(frameIndex) median=\(spikeProfile.median) torsoYhRun=\(spikeProfile.detYHRun) rawDetY=\(rawDetY) torsoDetY=\(torsoDetY) rows=[\(spikeProfile.profile)]")
        }

        // DIAG: dump per-column gate stats for the winning blob
        let detectCols = Array(gMin...gMax).filter { $0 >= 0 && $0 < W }
        let detectNeed = max(3, Int(Float(H) * minGateHeightFraction))
        logGateDiagPrefix("DETECT_DIAG", comp: c, columns: detectCols, need: detectNeed,
                          avg: candidate.run, winStart: candidate.winStart,
                          sliceWidth: min(sliceWidth, detectCols.count))

        // Reset buildup after logging — next crossing starts fresh
        gateBuildup = 0

        return DetectionResult(
            crossingTime: crossingTime,
            frameTimestamp: timestamp,
            interpolationFraction: fraction,
            dBefore: dBefore,
            dAfter: dAfter,
            movingLeftToRight: movingLeftToRight,
            gateY: torsoDetY,
            rawGateY: rawDetY,
            triggerHRun: candidate.torsoHRun,
            triggerBandRows: candidate.torsoBand,
            componentBounds: CGRect(
                x: CGFloat(c.minX) / CGFloat(W),
                y: CGFloat(c.minY) / CGFloat(H),
                width:  CGFloat(c.width)  / CGFloat(W),
                height: CGFloat(c.height) / CGFloat(H)
            ),
            thumbnailData: nil,
            isLandscapeBuffer: isLandscape
        )
    }

    // MARK: - Grayscale Extraction (Y plane direct read, with transpose support)

    private func extractGray(
        base: UnsafeMutableRawPointer, fullW: Int, fullH: Int, bpr: Int,
        w: Int, h: Int, transpose: Bool, into dest: inout [UInt8]
    ) {
        let src = base.assumingMemoryBound(to: UInt8.self)
        let sx = scaleX, sy = scaleY

        if transpose {
            // Y plane is landscape (fullW > fullH), rotate 90 for portrait
            // bufX maps to portrait Y (uses scaleY), bufY maps to portrait X (uses scaleX)
            for ty in 0..<h {
                let bufX = ty * sy
                for tx in 0..<w {
                    let bufY = tx * sx
                    dest[ty * w + tx] = src[bufY * bpr + bufX]
                }
            }
        } else {
            // Y plane is already portrait
            for ty in 0..<h {
                let rowOff = ty * sy * bpr
                for tx in 0..<w {
                    dest[ty * w + tx] = src[rowOff + tx * sx]
                }
            }
        }
    }

    // MARK: - Color Thumbnail (from YUV 420v biplanar, callable externally)

    /// Pre-warm the vImage thumbnail pipeline (conversion kernels, rotate, reflect,
    /// CGImage wrap, JPEG encode) to eliminate first-call cold start which otherwise
    /// drops ~17 capture frames the first time a crossing fires. Uses *real* 1280x720
    /// dimensions because vImage can lazily build per-size code paths on first
    /// encounter, and runs *both* orientation paths so switching cameras mid-session
    /// stays warm. Caller MUST run this on `DispatchQueue.global(qos: .utility)` —
    /// the same pool the real per-crossing thumbnail work uses — so any thread-pool
    /// or QoS-class first-touch state is built on the path that matters.
    static func prewarmThumbnail() {
        let w = 1280, h = 720
        let y = Data(repeating: 128, count: w * h)
        let cbcr = Data(repeating: 128, count: (w / 2) * (h / 2) * 2)
        // Back-camera path: transpose + horizontal flip (two vImage ops).
        _ = colorThumbnailFromPlanes(
            yData: y, yBpr: w,
            cbcrData: cbcr, cbcrBpr: (w / 2) * 2,
            fullW: w, fullH: h,
            transpose: true, mirrorX: false)
        // Front-camera path: transpose + mirror = pure 90° CW (one vImage op).
        _ = colorThumbnailFromPlanes(
            yData: y, yBpr: w,
            cbcrData: cbcr, cbcrBpr: (w / 2) * 2,
            fullW: w, fullH: h,
            transpose: true, mirrorX: true)
    }

    static func colorThumbnail(
        from pixelBuffer: CVPixelBuffer,
        transpose: Bool, mirrorX: Bool = false,
        thumbWidth: Int = 720, thumbHeight: Int = 1280, scale: Int = 1
    ) -> Data? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else { return nil }

        // Plane 0: Y (luma), full resolution
        let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!
            .assumingMemoryBound(to: UInt8.self)
        let yBpr = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)

        // Plane 1: CbCr (chroma), half resolution in each dimension
        let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)!
            .assumingMemoryBound(to: UInt8.self)
        let cbcrBpr = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        let w = thumbWidth, h = thumbHeight

        // Compute scale from pixel buffer dimensions to cover full frame
        let bufW = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let bufH = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let s: Int
        if transpose {
            s = max(max(bufW / h, 1), max(bufH / w, 1))
        } else {
            s = max(max(bufW / w, 1), max(bufH / h, 1))
        }

        guard let context = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        guard let data = context.data else { return nil }
        let dst = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        for ty in 0..<h {
            for tx in 0..<w {
                let bufX: Int, bufY: Int
                if transpose {
                    bufX = ty * s
                    bufY = tx * s
                } else {
                    bufX = tx * s
                    bufY = ty * s
                }

                // BT.709 video-range: Y [16-235], CbCr [16-240]
                let C = Int(yBase[bufY * yBpr + bufX]) - 16
                let cbcrOff = (bufY / 2) * cbcrBpr + (bufX / 2) * 2
                let Cb = Int(cbcrBase[cbcrOff])     - 128
                let Cr = Int(cbcrBase[cbcrOff + 1]) - 128

                // BT.709 video-range YCbCr -> RGB
                var R = (298 * C + 459 * Cr + 128) >> 8
                var G = (298 * C - 55 * Cb - 136 * Cr + 128) >> 8
                var B = (298 * C + 541 * Cb + 128) >> 8

                R = min(max(R, 0), 255)
                G = min(max(G, 0), 255)
                B = min(max(B, 0), 255)

                let dx = mirrorX ? (w - 1 - tx) : tx
                let dp = (ty * w + dx) * 4
                dst[dp]     = UInt8(R)
                dst[dp + 1] = UInt8(G)
                dst[dp + 2] = UInt8(B)
                dst[dp + 3] = 255
            }
        }

        guard let cgImage = context.makeImage() else { return nil }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cgImage,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    /// Generate color thumbnail from pre-copied Y + CbCr plane data (off-queue safe).
    static func colorThumbnailFromPlanes(
        yData: Data, yBpr: Int,
        cbcrData: Data, cbcrBpr: Int,
        fullW: Int, fullH: Int,
        transpose: Bool, mirrorX: Bool = false
    ) -> Data? {
        // 1. Build BT.709 video-range YpCbCr → ARGB conversion info.
        var info = vImage_YpCbCrToARGB()
        var pixelRange = vImage_YpCbCrPixelRange(
            Yp_bias: 16, CbCr_bias: 128,
            YpRangeMax: 235, CbCrRangeMax: 240,
            YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
        let infoErr = vImageConvert_YpCbCrToARGB_GenerateConversion(
            kvImage_YpCbCrToARGBMatrix_ITU_R_709_2, &pixelRange, &info,
            kvImage420Yp8_CbCr8, kvImageARGB8888,
            vImage_Flags(kvImageNoFlags))
        guard infoErr == kvImageNoError else { return nil }

        // 2. Allocate destination at source resolution.
        var rgbaBuf = vImage_Buffer()
        let allocErr = vImageBuffer_Init(&rgbaBuf,
                                         vImagePixelCount(fullH),
                                         vImagePixelCount(fullW),
                                         32, vImage_Flags(kvImageNoFlags))
        guard allocErr == kvImageNoError else { return nil }
        defer { free(rgbaBuf.data) }

        // 3. YUV planes → RGBA. permuteMap [1,2,3,0] turns ARGB output into RGBA.
        var permute: (UInt8, UInt8, UInt8, UInt8) = (1, 2, 3, 0)
        let convErr: vImage_Error = yData.withUnsafeBytes { yRaw in
            cbcrData.withUnsafeBytes { cbcrRaw in
                var yBuf = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: yRaw.baseAddress!),
                    height: vImagePixelCount(fullH),
                    width: vImagePixelCount(fullW),
                    rowBytes: yBpr)
                var cbcrBuf = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: cbcrRaw.baseAddress!),
                    height: vImagePixelCount(fullH / 2),
                    width: vImagePixelCount(fullW / 2),
                    rowBytes: cbcrBpr)
                return withUnsafePointer(to: &permute) { pPtr in
                    pPtr.withMemoryRebound(to: UInt8.self, capacity: 4) { pBytes in
                        vImageConvert_420Yp8_CbCr8ToARGB8888(
                            &yBuf, &cbcrBuf, &rgbaBuf, &info,
                            pBytes, 255,
                            vImage_Flags(kvImageNoFlags))
                    }
                }
            }
        }
        guard convErr == kvImageNoError else { return nil }

        // 4. Apply orientation. The legacy loop did out[ty][tx] = src[tx][ty] (matrix
        //    transpose), with optional horizontal mirror. Decomposes to:
        //      transpose, !mirror → 90° CW + horizontal flip
        //      transpose,  mirror → 90° CW (the two horizontal flips cancel)
        //      !transpose, mirror → horizontal flip
        //      !transpose,!mirror → identity
        let outW: Int
        let outH: Int
        if transpose { outW = fullH; outH = fullW }
        else         { outW = fullW; outH = fullH }

        var orientedBuf = vImage_Buffer()
        let orientAllocErr = vImageBuffer_Init(&orientedBuf,
                                               vImagePixelCount(outH),
                                               vImagePixelCount(outW),
                                               32, vImage_Flags(kvImageNoFlags))
        guard orientAllocErr == kvImageNoError else { return nil }
        defer { free(orientedBuf.data) }

        if transpose {
            var bg: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 255)
            let rotErr = withUnsafePointer(to: &bg) { bgPtr in
                bgPtr.withMemoryRebound(to: UInt8.self, capacity: 4) { bgBytes in
                    vImageRotate90_ARGB8888(&rgbaBuf, &orientedBuf, 3, bgBytes,
                                            vImage_Flags(kvImageNoFlags))
                }
            }
            guard rotErr == kvImageNoError else { return nil }
            if !mirrorX {
                let flipErr = vImageHorizontalReflect_ARGB8888(
                    &orientedBuf, &orientedBuf, vImage_Flags(kvImageNoFlags))
                guard flipErr == kvImageNoError else { return nil }
            }
        } else if mirrorX {
            let flipErr = vImageHorizontalReflect_ARGB8888(
                &rgbaBuf, &orientedBuf, vImage_Flags(kvImageNoFlags))
            guard flipErr == kvImageNoError else { return nil }
        } else {
            for r in 0..<outH {
                memcpy(orientedBuf.data.advanced(by: r * orientedBuf.rowBytes),
                       rgbaBuf.data.advanced(by: r * rgbaBuf.rowBytes),
                       outW * 4)
            }
        }

        // 5. Wrap as CGImage and JPEG-encode.
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGBitmapInfo.byteOrder32Big.rawValue |
            CGImageAlphaInfo.premultipliedLast.rawValue)
        guard var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            renderingIntent: .defaultIntent
        ) else { return nil }

        var cgErr: vImage_Error = kvImageNoError
        guard let cgImage = vImageCreateCGImageFromBuffer(
            &orientedBuf, &format, nil, nil,
            vImage_Flags(kvImageNoFlags), &cgErr
        )?.takeRetainedValue() else { return nil }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cgImage,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    // MARK: - Connected Components (8-way, union-find, optimized)

    private var parentBuf = [Int32]()
    private var compBuf   = [Component]()

    private func findComponents() -> [Component] {
        let W = processWidth, H = processHeight
        let count = W * H

        labels.withUnsafeMutableBufferPointer { lp in
            _ = memset(lp.baseAddress!, 0, count * MemoryLayout<Int32>.size)
        }

        var nextLabel: Int32 = 1
        let maxLabels = count / 4 + 256
        if parentBuf.count < maxLabels {
            parentBuf = [Int32](repeating: 0, count: maxLabels)
        }
        if compBuf.count < maxLabels {
            compBuf = [Component](repeating: Component(), count: maxLabels)
        }

        // Use unsafe pointers throughout to avoid bounds checks
        parentBuf.withUnsafeMutableBufferPointer { pp in
            labels.withUnsafeMutableBufferPointer { lp in
                maskBuf.withUnsafeBufferPointer { mp in

                    func find(_ x: Int32) -> Int32 {
                        var r = x
                        while pp[Int(r)] != r { r = pp[Int(r)] }
                        var c = x
                        while c != r { let n = pp[Int(c)]; pp[Int(c)] = r; c = n }
                        return r
                    }

                    func union(_ a: Int32, _ b: Int32) {
                        let ra = find(a), rb = find(b)
                        if ra != rb { pp[Int(ra)] = rb }
                    }

                    // Fixed-size neighbor buffer (max 4 for 8-way: TL, T, TR, L)
                    var nCount: Int = 0
                    var n0: Int32 = 0, n1: Int32 = 0, n2: Int32 = 0, n3: Int32 = 0

                    for y in 0..<H {
                        for x in 0..<W {
                            let idx = y * W + x
                            guard mp[idx] != 0 else { continue }

                            nCount = 0
                            if y > 0 && x > 0   { let l = lp[(y-1)*W+(x-1)]; if l > 0 { n0 = l; nCount = 1 } }
                            if y > 0             { let l = lp[(y-1)*W+x];     if l > 0 { switch nCount { case 0: n0 = l; case 1: n1 = l; case 2: n2 = l; default: n3 = l }; nCount += 1 } }
                            if y > 0 && x < W-1 { let l = lp[(y-1)*W+(x+1)]; if l > 0 { switch nCount { case 0: n0 = l; case 1: n1 = l; case 2: n2 = l; default: n3 = l }; nCount += 1 } }
                            if x > 0             { let l = lp[y*W+(x-1)];     if l > 0 { switch nCount { case 0: n0 = l; case 1: n1 = l; case 2: n2 = l; default: n3 = l }; nCount += 1 } }

                            if nCount == 0 {
                                let lbl = nextLabel
                                pp[Int(lbl)] = lbl
                                lp[idx] = lbl
                                nextLabel += 1
                            } else {
                                let minL = nCount == 1 ? n0 :
                                           nCount == 2 ? min(n0, n1) :
                                           nCount == 3 ? min(n0, min(n1, n2)) :
                                           min(n0, min(n1, min(n2, n3)))
                                lp[idx] = minL
                                if nCount >= 2 { union(n0, minL); union(n1, minL) }
                                if nCount >= 3 { union(n2, minL) }
                                if nCount >= 4 { union(n3, minL) }
                            }
                        }
                    }

                    // Pass 2: resolve labels and gather stats into array
                    // Reset comp stats for used labels
                    for i in 1..<Int(nextLabel) {
                        compBuf[i] = Component()
                    }

                    for y in 0..<H {
                        for x in 0..<W {
                            let idx = y * W + x
                            let lbl = lp[idx]
                            guard lbl > 0 else { continue }
                            let root = find(lbl)
                            lp[idx] = root
                            let ri = Int(root)
                            if x < compBuf[ri].minX { compBuf[ri].minX = x }
                            if x > compBuf[ri].maxX { compBuf[ri].maxX = x }
                            if y < compBuf[ri].minY { compBuf[ri].minY = y }
                            if y > compBuf[ri].maxY { compBuf[ri].maxY = y }
                            compBuf[ri].area += 1
                        }
                    }
                }
            }
        }

        // Collect non-empty components
        var result = [Component]()
        for i in 1..<Int(nextLabel) {
            if compBuf[i].area > 0 {
                result.append(compBuf[i])
            }
        }
        return result
    }

    // MARK: - Gate Analysis (leading-edge scan per spec 6.2-6.3)

    private let minGateHeightFraction: Float = 0.08 // frame-absolute floor for gate support

    private let sliceWidth = 3 // multi-column window for local support scoring

    private func analyzeGate(comp: Component, gMin: Int, gMax: Int) -> GateAnalysis? {
        let W = processWidth, H = processHeight
        // §18 H2 fix (2026-04-11): drop `heightForNeed × localSupportFraction`.
        // The h-scaled term caused ratcheting — `need` climbed faster than `run`
        // while the body was still entering the frame, killing near-qualifying
        // crossings one row short. Counterfactual data in session_2026-04-11_184832
        // (LS_COUNTERFACT lines) confirmed the floor-only rule recovers 4 of 6 misses.
        let minSupport = max(3, Int(Float(H) * minGateHeightFraction))

        // Compute best vertical run for each gate column (full blob range).
        // colRuns drives the local_support fire condition regardless of pickerMode.
        // colMids is the fallback Y pick for longestRun mode.
        let columns = Array(gMin...gMax).filter { $0 >= 0 && $0 < W }
        guard !columns.isEmpty else { return nil }

        var colRuns = [Int](repeating: 0, count: columns.count)
        var colMids = [Int](repeating: 0, count: columns.count)

        for (ci, gx) in columns.enumerated() {
            var runStart = -1
            var runLen   = 0
            var best     = 0
            var bestMid  = 0

            for y in comp.minY...comp.maxY {
                if maskBuf[y * W + gx] != 0 {
                    if runStart < 0 { runStart = y }
                    runLen += 1
                } else {
                    if runLen > best { best = runLen; bestMid = runStart + runLen / 2 }
                    runStart = -1; runLen = 0
                }
            }
            if runLen > best { best = runLen; bestMid = runStart + runLen / 2 }
            colRuns[ci] = best
            colMids[ci] = bestMid
        }

        // §12.5 Picker mode: compute colPickMids — the Y values used for detectionY.
        // For longestRun (current), colPickMids == colMids.
        // For topThird / absoluteFloor, restrict the Y scan to bias detectionY upward.
        var colPickMids = colMids

        if pickerMode != .longestRun {
            // Determine the upper Y ceiling for the restricted scan
            let ceilY: Int
            switch pickerMode {
            case .longestRun:
                ceilY = comp.maxY  // unreachable
            case .topThird:
                ceilY = comp.minY + comp.height / 3
            case .absoluteFloor:
                // For floor mode, refuse to fire entirely if no gate pixel is above the floor.
                // This tests hypothesis B: PF ignores blobs entirely in the lower frame.
                let floor = absolutePickerFloor
                // Guard: if the blob is entirely at or below the floor, refuse to fire.
                let floorScanTop = comp.minY
                let floorScanBot = min(floor - 1, comp.maxY)
                guard floorScanBot >= floorScanTop else {
                    return GateAnalysis(hasQualifyingSlice: false, detectionY: comp.minY,
                                        maxVerticalRun: 0, winWindowStart: -1)
                }
                let hasAboveFloor = columns.contains { gx in
                    (floorScanTop...floorScanBot).contains { y in
                        maskBuf[y * W + gx] != 0
                    }
                }
                guard hasAboveFloor else {
                    return GateAnalysis(hasQualifyingSlice: false, detectionY: comp.minY,
                                        maxVerticalRun: 0, winWindowStart: -1)
                }
                ceilY = floor - 1
            }

            let scanTop = comp.minY
            let scanBot = min(ceilY, comp.maxY)
            if scanTop <= scanBot {
                for (ci, gx) in columns.enumerated() {
                    var runStart = -1, runLen = 0, best = 0, bestMid = 0
                    for y in scanTop...scanBot {
                        if maskBuf[y * W + gx] != 0 {
                            if runStart < 0 { runStart = y }
                            runLen += 1
                        } else {
                            if runLen > best { best = runLen; bestMid = runStart + runLen / 2 }
                            runStart = -1; runLen = 0
                        }
                    }
                    if runLen > best { best = runLen; bestMid = runStart + runLen / 2 }
                    // Only override if we found pixels in the restricted range
                    if best > 0 { colPickMids[ci] = bestMid }
                }
            }
        }

        // Determine scan direction from leading edge
        let compCenterX = (comp.minX + comp.maxX) / 2
        let movingRight = compCenterX < gateColumn

        // Sliding window: require average run across `sliceWidth` adjacent columns.
        // Using average (not minimum) models a graded score — one weak column
        // doesn't kill the window, matching Photo Finish's smooth bottle transition.
        let sw = min(sliceWidth, columns.count)
        let windowCount = columns.count - sw + 1

        // Build ordered window indices from leading edge
        let windowIndices: [Int]
        if movingRight {
            // Leading edge on right → start from highest column index
            windowIndices = (0..<windowCount).reversed().map { $0 }
        } else {
            windowIndices = (0..<windowCount).map { $0 }
        }

        var overallBestAvg = 0
        var overallBestMid = 0
        var overallBestWi = -1

        for wi in windowIndices {
            // Average run across all columns in this window.
            // colRuns → fire decision; colPickMids → Y placement.
            var sumRun = 0
            var sumMid = 0
            for j in wi..<(wi + sw) {
                sumRun += colRuns[j]
                sumMid += colPickMids[j]
            }
            let avgRun = sumRun / sw

            if avgRun > overallBestAvg {
                overallBestAvg = avgRun
                overallBestMid = sumMid / sw
                overallBestWi = wi
            }

            if avgRun >= minSupport {
                return GateAnalysis(
                    hasQualifyingSlice: true,
                    detectionY: sumMid / sw,
                    maxVerticalRun: avgRun,
                    winWindowStart: wi
                )
            }
        }

        guard overallBestAvg > 0 else { return nil }
        // DIAG: log near-misses (>=70% of need) so we can see column profiles
        if overallBestAvg * 10 >= minSupport * 7 {
            logGateDiag(comp: comp, columns: columns, need: minSupport,
                        avg: overallBestAvg, winStart: overallBestWi, sliceWidth: sw)
        }
        return GateAnalysis(
            hasQualifyingSlice: false,
            detectionY: overallBestMid,
            maxVerticalRun: overallBestAvg,
            winWindowStart: overallBestWi
        )
    }

    // MARK: - §19 Torso Gate Row (Test X fix)
    //
    // Split the gate analysis into two stages: Stage 1 (analyzeGate) decides
    // "motion is present at the gate", Stage 2 (pickTorsoGateRow) decides
    // "*what kind* of motion — limb or torso". Firing only happens when a
    // torso-like band exists at the gate column. The returned torso row
    // replaces the downstream detY used for timing, interpolation, and the
    // thumbnail marker — this removes the old post-hoc frameBiasCap clamp
    // that kept firing on limbs and only moved the dot cosmetically.
    //
    // Plan-provided constants (tune after next side-by-side):
    //   torsoMinHRun      = 18   (min horizontal run to count as torso row)
    //   torsoBandRows     = 5    (rows meeting torsoMinHRun in the window)
    //   torsoWindowRows   = 7    (±3 rows centered on the candidate)
    //   torsoSearchMaxFrac = 0.55 (upper-portion ceiling, applied as
    //                              max of frame-relative and blob-relative;
    //                              see pickTorsoGateRow for exact semantics)

    private struct TorsoGateResult {
        var y: Int           // chosen torso row (absolute frame Y)
        var hRun: Int        // horizontal mask run at the chosen row
        var bandRows: Int    // rows in the 7-row window meeting torsoMinHRun
    }

    /// Scan top-down through the blob's vertical range at the gate column and
    /// return the first row whose horizontal mask run is torso-like AND sits
    /// inside a stable band of similar rows. Returns nil when only thin-limb
    /// or spike-like rows exist — the caller must NOT fire in that case.
    private func pickTorsoGateRow(comp: Component) -> TorsoGateResult? {
        let W = processWidth, H = processHeight
        // Blob-relative ceiling: upper torsoSearchMaxFrac of the blob itself.
        // Frame-relative ceiling: upper torsoSearchMaxFrac of the frame
        // (legacy behavior). Take the deeper (more permissive) of the two so
        // tall Test W blobs keep their old frame-relative ceiling bitwise
        // intact while short/low Test Y/Z blobs unlock their own upper
        // portion. `min(comp.maxY, …)` still clamps to the actual blob
        // extent, so we never scan outside the blob.
        let blobHeight = comp.maxY - comp.minY + 1
        let blobUpperCeiling = comp.minY + Int(Float(blobHeight) * torsoSearchMaxFrac)
        let frameUpperCeiling = Int(Float(H) * torsoSearchMaxFrac)
        let searchMaxY = min(comp.maxY, max(frameUpperCeiling, blobUpperCeiling))
        guard comp.minY <= searchMaxY else { return nil }

        let half = torsoWindowRows / 2  // 7→3
        // Include window overhang below searchMaxY so windows centered on
        // the last legal candidate row are fully defined.
        let scanTop = comp.minY
        let scanBot = min(comp.maxY, searchMaxY + half)
        guard scanTop <= scanBot else { return nil }

        let rowCount = scanBot - scanTop + 1
        var hRuns = [Int](repeating: 0, count: rowCount)
        for i in 0..<rowCount {
            let y = scanTop + i
            guard maskBuf[y * W + gateColumn] != 0 else {
                hRuns[i] = 0
                continue
            }
            var lx = gateColumn, rx = gateColumn
            var sx = gateColumn - 1
            while sx >= 0 && maskBuf[y * W + sx] != 0 { lx = sx; sx -= 1 }
            sx = gateColumn + 1
            while sx < W && maskBuf[y * W + sx] != 0 { rx = sx; sx += 1 }
            hRuns[i] = rx - lx + 1
        }

        // Spike rejection uses the same median × 1.5 rule as adjustForArmSpike.
        // An arm sticking forward inflates one or two rows well above the
        // median torso width and must not be picked as the torso row.
        let nonZero = hRuns.filter { $0 > 0 }.sorted()
        let median = nonZero.isEmpty ? 0 : nonZero[nonZero.count / 2]
        let spikeThreshold = Float(median) * spikeRatioThreshold

        let lastCandidateIdx = searchMaxY - scanTop
        guard lastCandidateIdx >= 0 else { return nil }

        // Scan qualifying rows and group them into contiguous bands.
        // Pick the center of the longest band — naturally mid-torso,
        // since the shoulder-to-hip region is the longest continuous
        // qualifying band for a side-view human body.
        var bands: [(startIdx: Int, length: Int)] = []
        var bandStart = -1

        for i in 0...lastCandidateIdx {
            let h = hRuns[i]
            var qualifies = false
            if h >= torsoMinHRun && (median == 0 || Float(h) <= spikeThreshold) {
                let lo = max(0, i - half)
                let hi = min(rowCount - 1, i + half)
                var band = 0
                for j in lo...hi where hRuns[j] >= torsoMinHRun { band += 1 }
                qualifies = band >= torsoBandRows
            }
            if qualifies {
                if bandStart == -1 { bandStart = i }
            } else if bandStart != -1 {
                bands.append((startIdx: bandStart, length: i - bandStart))
                bandStart = -1
            }
        }
        if bandStart != -1 {
            bands.append((startIdx: bandStart, length: lastCandidateIdx + 1 - bandStart))
        }
        guard !bands.isEmpty else { return nil }

        // Pick the longest band. Tie-break: center closest to blob center.
        let maxLen = bands.map(\.length).max()!
        let blobCenterY = (comp.minY + comp.maxY) / 2
        let bestBand = bands.filter { $0.length == maxLen }
            .min { abs(scanTop + $0.startIdx + $0.length/2 - blobCenterY)
                 < abs(scanTop + $1.startIdx + $1.length/2 - blobCenterY) }!

        let centerIdx = bestBand.startIdx + bestBand.length / 2
        // Recompute bandRows for the center row's 7-row window.
        let lo = max(0, centerIdx - half)
        let hi = min(rowCount - 1, centerIdx + half)
        var bandCount = 0
        for j in lo...hi where hRuns[j] >= torsoMinHRun { bandCount += 1 }

        return TorsoGateResult(y: scanTop + centerIdx, hRun: hRuns[centerIdx], bandRows: bandCount)
    }

    // MARK: - §15 Arm-Spike Correction
    //
    // From the side, a torso has uniform horizontal extent per row (~22-24 px)
    // but an arm sticking forward creates a sharp spike (~50+ px) at the arm
    // rows. This function detects that spike in the per-row hRun profile and
    // shifts detY away from it, into the longest contiguous band of non-spike
    // (torso) rows.

    private struct SpikeResult {
        var adjustedDetY: Int
        var profile: String    // sampled per-row hRun for [HRUN_PROFILE] logging
        var median: Int
        var detYHRun: Int
        var corrected: Bool
    }

    private func adjustForArmSpike(detY: Int, comp: Component) -> SpikeResult {
        let W = processWidth

        // Find the contiguous vertical mask run at the gate column containing detY
        guard detY >= 0, detY < processHeight,
              maskBuf[detY * W + gateColumn] != 0 else {
            return SpikeResult(adjustedDetY: detY, profile: "", median: 0, detYHRun: 0, corrected: false)
        }

        var runTop = detY
        while runTop > comp.minY && maskBuf[(runTop - 1) * W + gateColumn] != 0 { runTop -= 1 }
        var runBot = detY
        while runBot < comp.maxY && maskBuf[(runBot + 1) * W + gateColumn] != 0 { runBot += 1 }

        let runHeight = runBot - runTop + 1
        guard runHeight >= 10 else {
            return SpikeResult(adjustedDetY: detY, profile: "", median: 0, detYHRun: 0, corrected: false)
        }

        // Compute hRun + xMin/xMax at each row in the run by scanning left/right from gate
        var rowHRuns = [Int](repeating: 0, count: runHeight)
        var rowXMin = [Int](repeating: 0, count: runHeight)
        var rowXMax = [Int](repeating: 0, count: runHeight)
        for i in 0..<runHeight {
            let y = runTop + i
            var lx = gateColumn, rx = gateColumn
            var sx = gateColumn - 1
            while sx >= 0 && maskBuf[y * W + sx] != 0 { lx = sx; sx -= 1 }
            sx = gateColumn + 1
            while sx < W && maskBuf[y * W + sx] != 0 { rx = sx; sx += 1 }
            rowHRuns[i] = rx - lx + 1
            rowXMin[i] = lx
            rowXMax[i] = rx
        }

        // Median hRun
        let sorted = rowHRuns.sorted()
        let median = sorted[sorted.count / 2]
        let threshold = Float(median) * spikeRatioThreshold

        let detIdx = detY - runTop
        let detYHRun = (detIdx >= 0 && detIdx < runHeight) ? rowHRuns[detIdx] : 0

        // Build sampled profile log string (~30 samples max to keep log manageable)
        // Format: y:hRun(xMin-xMax)  e.g. 235:8(69-76) means row 235 is 8px wide from x=69 to x=76
        let step = max(1, runHeight / 30)
        var parts = [String]()
        for i in stride(from: 0, to: runHeight, by: step) {
            let y = runTop + i
            let spike = Float(rowHRuns[i]) > threshold ? "*" : ""
            parts.append("\(y):\(rowHRuns[i])(\(rowXMin[i])-\(rowXMax[i]))\(spike)")
        }
        let profileStr = parts.joined(separator: " ")

        // If detY's hRun is not a spike, return unchanged
        guard Float(detYHRun) > threshold, median > 0 else {
            return SpikeResult(adjustedDetY: detY, profile: profileStr, median: median, detYHRun: detYHRun, corrected: false)
        }

        // Spike detected — find the longest contiguous band of non-spike rows
        var bestStart = 0, bestLen = 0
        var curStart = 0, curLen = 0

        for i in 0..<runHeight {
            if Float(rowHRuns[i]) <= threshold {
                if curLen == 0 { curStart = i }
                curLen += 1
            } else {
                if curLen > bestLen { bestLen = curLen; bestStart = curStart }
                curLen = 0
            }
        }
        if curLen > bestLen { bestLen = curLen; bestStart = curStart }

        guard bestLen > 0 else {
            return SpikeResult(adjustedDetY: detY, profile: profileStr, median: median, detYHRun: detYHRun, corrected: false)
        }

        let adjustedDetY = runTop + bestStart + bestLen / 2
        return SpikeResult(adjustedDetY: adjustedDetY, profile: profileStr, median: median, detYHRun: detYHRun, corrected: true)
    }

    // MARK: - §15 Tight fill: fill ratio excluding arm-spike rows
    //
    // When a raised arm inflates the bounding box, raw fill_ratio drops below
    // threshold even though the torso is solid. This function computes fill using
    // only non-spike rows (hRun ≤ median × 1.5) and returns the trimmed row count
    // so analyzeGate can use it for local_support need.
    //
    // Returns (tightFill, trimmedHeight). Returns (-1, 0) if not computable.
    private func computeTightFill(comp: Component) -> (Float, Int) {
        let W = processWidth

        // Find any mask pixel at the gate column within the blob's vertical range.
        // Scan from the vertical center outward to maximize chance of hitting the
        // main body run (not a thin arm fragment).
        let centerY = (comp.minY + comp.maxY) / 2
        var seedY = -1
        for offset in 0...(comp.maxY - comp.minY) {
            let yUp = centerY - offset
            let yDown = centerY + offset
            if yUp >= comp.minY && maskBuf[yUp * W + gateColumn] != 0 {
                seedY = yUp; break
            }
            if yDown <= comp.maxY && maskBuf[yDown * W + gateColumn] != 0 {
                seedY = yDown; break
            }
        }
        guard seedY >= 0 else { return (-1, 0) }

        // Expand up/down from seed to find contiguous gate-column run
        var runTop = seedY
        while runTop > comp.minY && maskBuf[(runTop - 1) * W + gateColumn] != 0 { runTop -= 1 }
        var runBot = seedY
        while runBot < comp.maxY && maskBuf[(runBot + 1) * W + gateColumn] != 0 { runBot += 1 }

        let runHeight = runBot - runTop + 1
        guard runHeight >= 10 else { return (-1, 0) }

        // Compute hRun per row
        var hRuns = [Int]()
        for y in runTop...runBot {
            var lx = gateColumn, rx = gateColumn
            var sx = gateColumn - 1
            while sx >= 0 && maskBuf[y * W + sx] != 0 { lx = sx; sx -= 1 }
            sx = gateColumn + 1
            while sx < W && maskBuf[y * W + sx] != 0 { rx = sx; sx += 1 }
            hRuns.append(rx - lx + 1)
        }

        let sorted = hRuns.sorted()
        let median = sorted[sorted.count / 2]
        guard median > 0 else { return (-1, 0) }
        let threshold = Float(median) * spikeRatioThreshold

        // Count non-spike rows and their total hRun (gate-local area proxy)
        var nonSpikeRows = 0
        var nonSpikeArea = 0
        for h in hRuns {
            if Float(h) <= threshold {
                nonSpikeRows += 1
                nonSpikeArea += h
            }
        }
        guard nonSpikeRows > 0 else { return (-1, 0) }

        let tightFill = Float(nonSpikeArea) / Float(comp.width * nonSpikeRows)
        return (tightFill, nonSpikeRows)
    }

    // MARK: - Diagnostic: per-column gate stats
    //
    // Temporary instrumentation. For each gate-band column, prints longest
    // contiguous run, total mask pixels, distinct run count, and largest
    // interior gap. Lets us distinguish "sparse mask" (lng ≈ tot) from
    // "gappy mask" (tot >> lng) when picking the next fix.
    //
    // Test G (2026-04-07) follow-up: also tracks topmost mask pixel,
    // topmost run, and second-longest run per column. These are needed
    // to design the picker fix for the lean-severity bias — see
    // detector_hypotheses.md §11. Diagnostic-only; analyzeGate still
    // uses the longest-run midpoint exactly as before.

    private struct ColStats {
        var longest: Int
        var longestStart: Int  // y of first pixel in longest run (-1 if none)
        var longestEnd: Int    // y of last pixel in longest run (-1 if none)
        var totalPx: Int
        var runCount: Int
        var maxGap: Int
        // §11 fields (Test G follow-up): used to evaluate candidate
        // picker rules against existing logs without changing behavior.
        var topmostMaskY: Int   // y of topmost non-zero mask pixel, -1 if none
        var topmostLen: Int     // length of topmost run, 0 if none
        var topmostStart: Int   // y of first pixel of topmost run, -1 if none
        var topmostEnd: Int     // y of last pixel of topmost run, -1 if none
        var secondLen: Int      // length of second-longest run, 0 if none
        var secondStart: Int    // y of first pixel of second-longest run, -1 if none
        var secondEnd: Int      // y of last pixel of second-longest run, -1 if none
        // Full per-column run dump (added 2026-04-07 follow-up to §11.5):
        // every contiguous mask run in scan order, top-down. Lets us fit
        // gradient-shape candidates (run-length-weighted Y-centroid,
        // length-thresholded top-down scans, etc.) against existing logs
        // without yet another instrumentation round. See
        // detector_hypotheses.md §11.5.
        var allRuns: [(start: Int, end: Int)]
    }

    private func columnStats(gx: Int, comp: Component) -> ColStats {
        let W = processWidth
        var longest = 0
        var longestStart = -1
        var longestEnd = -1
        var secondLen = 0
        var secondStart = -1
        var secondEnd = -1
        var topmostMaskY = -1
        var topmostLen = 0
        var topmostStart = -1
        var topmostEnd = -1
        var allRuns: [(start: Int, end: Int)] = []
        var curRun = 0
        var curRunStart = -1
        var totalPx = 0
        var runCount = 0
        var maxGap = 0
        var curGap = 0
        var seenRun = false

        // Closes the currently open run (curRun > 0 implied) and folds it
        // into the longest / second-longest / topmost trackers, and into
        // the full allRuns dump.
        func closeRun(endY: Int) {
            // Topmost run = the first run encountered scanning top-down.
            if topmostLen == 0 {
                topmostLen = curRun
                topmostStart = curRunStart
                topmostEnd = endY
            }
            // Maintain top-2 by length.
            if curRun > longest {
                secondLen = longest
                secondStart = longestStart
                secondEnd = longestEnd
                longest = curRun
                longestStart = curRunStart
                longestEnd = endY
            } else if curRun > secondLen {
                secondLen = curRun
                secondStart = curRunStart
                secondEnd = endY
            }
            allRuns.append((start: curRunStart, end: endY))
        }

        for y in comp.minY...comp.maxY {
            if maskBuf[y * W + gx] != 0 {
                if topmostMaskY == -1 { topmostMaskY = y }
                if curRun == 0 {
                    runCount += 1
                    curRunStart = y
                    if seenRun && curGap > maxGap { maxGap = curGap }
                }
                curRun += 1
                totalPx += 1
                curGap = 0
                seenRun = true
            } else {
                if curRun > 0 {
                    closeRun(endY: y - 1)
                    curRun = 0
                }
                if seenRun { curGap += 1 }
            }
        }
        if curRun > 0 {
            closeRun(endY: comp.maxY)
        }

        return ColStats(
            longest: longest, longestStart: longestStart, longestEnd: longestEnd,
            totalPx: totalPx, runCount: runCount, maxGap: maxGap,
            topmostMaskY: topmostMaskY,
            topmostLen: topmostLen, topmostStart: topmostStart, topmostEnd: topmostEnd,
            secondLen: secondLen, secondStart: secondStart, secondEnd: secondEnd,
            allRuns: allRuns
        )
    }

    private func logGateDiag(comp: Component, columns: [Int], need: Int, avg: Int,
                             winStart: Int, sliceWidth: Int) {
        logGateDiagPrefix("GATE_DIAG", comp: comp, columns: columns, need: need, avg: avg,
                          winStart: winStart, sliceWidth: sliceWidth)
    }

    private func logGateDiagPrefix(_ tag: String, comp: Component, columns: [Int],
                                   need: Int, avg: Int,
                                   winStart: Int, sliceWidth: Int) {
        var detail = ""
        var colLongest = [Int]()
        for (ci, gx) in columns.enumerated() {
            let s = columnStats(gx: gx, comp: comp)
            colLongest.append(s.longest)
            // Mark the 3 columns that fed the winning (or best-so-far) slice
            let inWin = winStart >= 0 && ci >= winStart && ci < winStart + sliceWidth
            let marker = inWin ? ">" : " "
            // Existing fields (kept verbatim for backward compat with Test A–G logs).
            if s.longest > 0 {
                detail += String(format: "%@c%d:lng=%d@%d..%d/tot=%d/runs=%d/maxGap=%d",
                                 marker, gx,
                                 s.longest, s.longestStart, s.longestEnd,
                                 s.totalPx, s.runCount, s.maxGap)
            } else {
                detail += String(format: "%@c%d:lng=0/tot=%d/runs=%d/maxGap=%d",
                                 marker, gx, s.totalPx, s.runCount, s.maxGap)
            }
            // §11 fields (Test G follow-up): topmost mask y, topmost run,
            // second-longest run. See detector_hypotheses.md §11.4/§11.5.
            detail += "/tmY=\(s.topmostMaskY)"
            if s.topmostLen > 0 {
                detail += "/top=\(s.topmostLen)@\(s.topmostStart)..\(s.topmostEnd)"
            } else {
                detail += "/top=0"
            }
            if s.secondLen > 0 {
                detail += "/2nd=\(s.secondLen)@\(s.secondStart)..\(s.secondEnd)"
            } else {
                detail += "/2nd=0"
            }
            // Full per-column run dump (top-down). Compact "Y1..Y2,Y3..Y4,..."
            // notation. Empty string if the column had no mask. See
            // detector_hypotheses.md §11.5 — used to fit candidate
            // gradient-shape pickers against this run's frames.
            if s.allRuns.isEmpty {
                detail += "/all="
            } else {
                let runStrs = s.allRuns.map { "\($0.start)..\($0.end)" }
                detail += "/all=" + runStrs.joined(separator: ",")
            }
        }
        // Per-column longest run range (max - min) and minimum.
        // Hand swipes produce uniform runs (range 1-9), body crossings uneven (range 13-52).
        let colRange = colLongest.isEmpty ? 0 : (colLongest.max()! - colLongest.min()!)
        let colMin = colLongest.min() ?? 0
        slog("[\(tag)] frame=\(frameIndex) blob=\(comp.width)x\(comp.height) need=\(need) avg=\(avg) colRange=\(colRange) colMin=\(colMin) buildup=\(gateBuildup) cols=[\(detail.trimmingCharacters(in: .whitespaces))]")
    }

    // MARK: - Logging

    private func logReject(_ reason: String, detail: String = "") {
        guard reason != lastRejectReason else { return }
        lastRejectReason = reason
        if detail.isEmpty {
            slog("[REJECT] frame=\(frameIndex) \(reason)")
        } else {
            slog("[REJECT] frame=\(frameIndex) \(reason) — \(detail)")
        }
    }
}
