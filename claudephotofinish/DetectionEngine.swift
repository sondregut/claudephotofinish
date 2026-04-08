import Foundation
import CoreMedia
import CoreVideo
import UIKit
import ImageIO
import Accelerate

// MARK: - Detection Result

struct DetectionResult {
    let crossingTime: TimeInterval
    let frameTimestamp: CMTime
    let interpolationFraction: Double   // 0..1 — how far between N-1 and N the crossing occurred
    let dBefore: Float                  // pixels from old leading edge to gate
    let dAfter: Float                   // pixels from gate to new leading edge
    let movingLeftToRight: Bool
    let gateY: Int
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
    private let heightFraction: Float   = 0.33
    private let widthFraction:  Float   = 0.08
    // Reverted 2026-04-07 from 0.15 → 0.25 after the post-Test-N cross-tab
    // in test_runs_our_detector.md showed that 5 of 7 Test N elbow leakers
    // have run/h < 25% while every Tests F/G/H body crossing has run/h ≥ 25%.
    // The 0.15 value (commit 8003aca "Lower detection thresholds for earlier
    // firing") was opening the leak path for most elbow swipes.
    private let localSupportFraction: Float = 0.25
    private let minFillRatio: Float = 0.20       // reject sparse blobs (hand swipes)
    private let maxAspectRatio: Float = 1.2      // reject wide-flat blobs (legs/hand swipes)
    private let frameBiasCap: Float = 0.55       // §12.5 hypothesis B: clamp detY to top 55% of frame
    private let warmupFrames: Int = 10           // skip early frames while auto-exposure settles

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
        hasPrevious = false
        lastRejectReason = ""
        frameIndex = 0
        lastFullW = 0
        print("[ENGINE] started, process=\(processWidth)x\(processHeight)")
    }

    func stop() {
        isActive = false
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
            print("[INIT] buffer=\(fullW)x\(fullH) bpr=\(bpr) landscape=\(isLandscape) process=\(processWidth)x\(processHeight) scaleX=\(scaleX) scaleY=\(scaleY)")
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

        // 5. Gate detection
        let minH = Int(Float(H) * heightFraction)
        let minW = Int(Float(W) * widthFraction)
        let gMin = max(gateColumn - gateBandHalf, 0)
        let gMax = min(gateColumn + gateBandHalf, W - 1)

        var best: (comp: Component, detY: Int, run: Int, winStart: Int)?
        var candidateCount = 0
        let frameAbsMin = Int(Float(H) * minGateHeightFraction)
        var anyBlobAtGate = false

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
            if fillRatio < minFillRatio {
                logReject("fill_ratio", detail: String(format: "%.2f/%.2f area=%d", fillRatio, minFillRatio, comp.area))
                continue
            }
            if comp.width > Int(maxAspectRatio * Float(comp.height)) {
                logReject("aspect_ratio", detail: String(format: "w=%d h=%d ratio=%.1f", comp.width, comp.height, Float(comp.width) / Float(comp.height)))
                continue
            }
            guard comp.maxX >= gMin, comp.minX <= gMax else {
                logReject("no_gate_intersection")
                continue
            }

            if let analysis = analyzeGate(comp: comp, gMin: gMin, gMax: gMax) {
                anyBlobAtGate = true
                if analysis.hasQualifyingSlice {
                    candidateCount += 1
                    if best == nil || comp.area > best!.comp.area {
                        best = (comp, analysis.detectionY, analysis.maxVerticalRun, analysis.winWindowStart)
                    }
                } else {
                    let need = max(3, Int(Float(comp.height) * localSupportFraction), frameAbsMin)
                    logReject("local_support",
                              detail: "run=\(analysis.maxVerticalRun) need=\(need)")
                }
            }
        }

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

        // §12.5 frame-Y bias cap (hypothesis B): clamp picker output to top N% of frame.
        // If the picker lands below the cap (deeper into legs on lean crossings), snap up
        // to the cap. Safety floor: never clamp above the blob's topmost pixel.
        // Interpolation (detRow below) still uses the ORIGINAL picker Y for timing accuracy.
        let frameCap = Int(Float(processHeight) * frameBiasCap)
        let clampedDetY = max(candidate.comp.minY, min(candidate.detY, frameCap))

        // Log all size-qualified components for diagnostics
        let qualComps = components.filter { $0.height >= minH && $0.width >= minW }
        if qualComps.count > 1 || true {
            for (i, comp) in qualComps.enumerated() {
                let atGate = comp.maxX >= gMin && comp.minX <= gMax
                let tag = comp.area == candidate.comp.area ? ">>>" : "   "
                print(String(format: "[COMP] %@ #%d %dx%d x=%d..%d y=%d..%d area=%d gate=%@",
                             tag, i, comp.width, comp.height, comp.minX, comp.maxX, comp.minY, comp.maxY, comp.area, atGate ? "YES" : "no"))
            }
        }

        // Body-part suppression (spec 6.4):
        // If a larger size-qualified component exists in the frame that hasn't reached
        // the gate yet but is approaching, suppress this detection and wait for it.
        let approachZone = Int(Float(W) * 0.20) // within 20% of frame width
        for comp in components {
            guard comp.height >= minH, comp.width >= minW else { continue }
            guard comp.area > candidate.comp.area else { continue }
            // This larger component must NOT be at the gate
            guard comp.maxX < gMin || comp.minX > gMax else { continue }
            // Check if it's approaching the gate (leading edge within approach zone)
            let distToGate = comp.maxX < gMin ? (gMin - comp.maxX) : (comp.minX - gMax)
            if distToGate <= approachZone {
                logReject("body_part_suppression",
                          detail: "gate_area=\(candidate.comp.area) approaching_area=\(comp.area) dist=\(distToGate)")
                return nil
            }
        }

        // 6. Position-based interpolation (spec 7.1)
        // At the detection row (detY), find the continuous horizontal run of mask
        // pixels containing the gate. This is the leading-edge strip — its extent
        // on each side of the gate gives the distances for interpolation.
        let detRow = candidate.detY
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
        print(String(format: "[DETECT] blob=%dx%d hR=%.2f wR=%.2f fill=%.2f run=%d hRun=%d interp=%.0f/%.0f dir=%@ cands=%d area=%d x=%d..%d detY=%d rawDetY=%d frame=%d time=%.3f exp=%.2fms iso=%.0f buildup=%d",
                     c.width, c.height, hR, wR, fR, candidate.run, hRun, dBefore, dAfter, dir, candidateCount, c.area, c.minX, c.maxX, clampedDetY, candidate.detY, frameIndex, crossingTime, expMs, isoVal, buildupAtDetection))

        // DIAG: dump per-column gate stats for the winning blob
        let detectCols = Array(gMin...gMax).filter { $0 >= 0 && $0 < W }
        let detectNeed = max(3, Int(Float(c.height) * localSupportFraction),
                             Int(Float(H) * minGateHeightFraction))
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
            gateY: clampedDetY,
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
            [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    /// Generate color thumbnail from pre-copied Y + CbCr plane data (off-queue safe).
    static func colorThumbnailFromPlanes(
        yData: Data, yBpr: Int,
        cbcrData: Data, cbcrBpr: Int,
        fullW: Int, fullH: Int,
        transpose: Bool, mirrorX: Bool = false,
        thumbWidth: Int = 720, thumbHeight: Int = 1280, scale: Int = 1
    ) -> Data? {
        // thumbWidth/thumbHeight/scale are vestigial — output is always at source resolution
        // (after orientation), produced via Accelerate so we don't stall the capture pipeline.
        _ = thumbWidth; _ = thumbHeight; _ = scale

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
                                if nCount >= 2 { union(n1, minL) }
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
        let minSupport = max(3, Int(Float(comp.height) * localSupportFraction),
                             Int(Float(H) * minGateHeightFraction))

        // Compute best vertical run for each gate column
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
            // Average run across all columns in this window
            var sumRun = 0
            var sumMid = 0
            for j in wi..<(wi + sw) {
                sumRun += colRuns[j]
                sumMid += colMids[j]
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
        print("[\(tag)] frame=\(frameIndex) blob=\(comp.width)x\(comp.height) need=\(need) avg=\(avg) colRange=\(colRange) colMin=\(colMin) buildup=\(gateBuildup) cols=[\(detail.trimmingCharacters(in: .whitespaces))]")
    }

    // MARK: - Logging

    private func logReject(_ reason: String, detail: String = "") {
        guard reason != lastRejectReason else { return }
        lastRejectReason = reason
        if detail.isEmpty {
            print("[REJECT] frame=\(frameIndex) \(reason)")
        } else {
            print("[REJECT] frame=\(frameIndex) \(reason) — \(detail)")
        }
    }
}
