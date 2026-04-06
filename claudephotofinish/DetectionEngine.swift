import Foundation
import CoreMedia
import CoreVideo
import UIKit
import ImageIO

// MARK: - Detection Result

struct DetectionResult {
    let crossingTime: TimeInterval
    let frameTimestamp: CMTime
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
}

// MARK: - Detection Engine

final class DetectionEngine {

    // Processing resolution (portrait: width < height)
    let processWidth  = 180
    let processHeight = 320
    private let scale = 4    // downsample factor

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
    private let diffThreshold: UInt8    = 25
    private let heightFraction: Float   = 0.30
    private let widthFraction:  Float   = 0.08
    private let localSupportFraction: Float = 0.15
    private let minFillRatio: Float = 0.25       // reject sparse blobs (hand swipes)
    private let maxAspectRatio: Float = 1.8      // reject wide-flat blobs (w/h > 1.8)
    private let warmupFrames: Int = 10           // skip early frames while auto-exposure settles

    // Gate
    private var gateColumn: Int { processWidth / 2 }
    private let gateBandHalf: Int = 2

    // Session state
    private(set) var isActive = false
    var isFrontCamera = false
    private var sessionStart: CMTime?
    private var lastDetectionElapsed: TimeInterval?
    private var lastDetectionRealElapsed: TimeInterval?   // actual frame time, for cooldown
    private let cooldown: TimeInterval = 0.5

    // Logging
    private var lastRejectReason = ""
    private var frameIndex = 0

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
        hasPrevious = false
        lastRejectReason = ""
        frameIndex = 0
        print("[ENGINE] started, process=\(processWidth)x\(processHeight) scale=\(scale)")
    }

    func stop() {
        isActive = false
    }

    func reset() {
        stop()
        sessionStart = nil
        lastDetectionElapsed = nil
        lastDetectionRealElapsed = nil
        hasPrevious = false
        frameIndex = 0
    }

    // MARK: Main Processing

    func processFrame(
        _ pixelBuffer: CVPixelBuffer,
        timestamp: CMTime,
        exposureDuration: CMTime?
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

        if frameIndex == 1 {
            print("[INIT] buffer=\(fullW)x\(fullH) bpr=\(bpr) landscape=\(isLandscape) process=\(processWidth)x\(processHeight)")
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

        var best: (comp: Component, detY: Int, run: Int)?
        var candidateCount = 0
        let frameAbsMin = Int(Float(H) * minGateHeightFraction)

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
            // Reject wide-flat blobs (hand swipes at close range)
            // Body crossings are taller than wide; hand swipes are wider than tall
            if comp.width > Int(maxAspectRatio * Float(comp.height)) {
                logReject("aspect_ratio", detail: String(format: "w=%d h=%d ratio=%.1f", comp.width, comp.height, Float(comp.width) / Float(comp.height)))
                continue
            }
            guard comp.maxX >= gMin, comp.minX <= gMax else {
                logReject("no_gate_intersection")
                continue
            }

            if let analysis = analyzeGate(comp: comp, gMin: gMin, gMax: gMax) {
                if analysis.hasQualifyingSlice {
                    candidateCount += 1
                    if best == nil || comp.area > best!.comp.area {
                        best = (comp, analysis.detectionY, analysis.maxVerticalRun)
                    }
                } else {
                    let need = max(3, Int(Float(comp.height) * localSupportFraction), frameAbsMin)
                    logReject("local_support",
                              detail: "run=\(analysis.maxVerticalRun) need=\(need)")
                }
            }
        }

        guard let candidate = best else { return nil }

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

        let dBefore = Float(gateColumn - runLeftX) // distance from body front in N-1 to gate
        let dAfter  = Float(runRightX - gateColumn) // distance from gate to body front in N
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
        lastRejectReason = ""

        let c = candidate.comp
        let hR = Float(c.height) / Float(H)
        let wR = Float(c.width) / Float(W)

        let fR = Float(c.area) / Float(c.width * c.height)
        print(String(format: "[DETECT] blob=%dx%d hR=%.2f wR=%.2f fill=%.2f run=%d interp=%.0f/%.0f cands=%d area=%d x=%d..%d detY=%d frame=%d time=%.3f",
                     c.width, c.height, hR, wR, fR, candidate.run, dBefore, dAfter, candidateCount, c.area, c.minX, c.maxX, candidate.detY, frameIndex, crossingTime))

        return DetectionResult(
            crossingTime: crossingTime,
            frameTimestamp: timestamp,
            gateY: candidate.detY,
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
        let s = scale

        if transpose {
            // Y plane is landscape (fullW > fullH), rotate 90 for portrait
            for ty in 0..<h {
                let bufX = ty * s
                for tx in 0..<w {
                    let bufY = tx * s
                    dest[ty * w + tx] = src[bufY * bpr + bufX]
                }
            }
        } else {
            // Y plane is already portrait
            for ty in 0..<h {
                let rowOff = ty * s * bpr
                for tx in 0..<w {
                    dest[ty * w + tx] = src[rowOff + tx * s]
                }
            }
        }
    }

    // MARK: - Color Thumbnail (from YUV 420v biplanar, callable externally)

    /// Pre-warm CGContext + JPEG encoder to eliminate first-call cold start.
    /// Call once on a background thread when detection starts.
    static func prewarmThumbnail() {
        guard let ctx = CGContext(
            data: nil, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        guard let img = ctx.makeImage() else { return }
        let d = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(d, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.5] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    static func colorThumbnail(
        from pixelBuffer: CVPixelBuffer,
        transpose: Bool, mirrorX: Bool = false,
        thumbWidth: Int = 90, thumbHeight: Int = 160, scale: Int = 8
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
        let s = scale

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

                // Video-range BT.601: Y [16-235], CbCr [16-240]
                let C = Int(yBase[bufY * yBpr + bufX]) - 16
                let cbcrOff = (bufY / 2) * cbcrBpr + (bufX / 2) * 2
                let D = Int(cbcrBase[cbcrOff])     - 128
                let E = Int(cbcrBase[cbcrOff + 1]) - 128

                // BT.601 video-range YCbCr -> RGB
                var R = (298 * C + 409 * E + 128) >> 8
                var G = (298 * C - 100 * D - 208 * E + 128) >> 8
                var B = (298 * C + 516 * D + 128) >> 8

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
            [kCGImageDestinationLossyCompressionQuality: 0.5] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    /// Generate color thumbnail from pre-copied Y + CbCr plane data (off-queue safe).
    static func colorThumbnailFromPlanes(
        yData: Data, yBpr: Int,
        cbcrData: Data, cbcrBpr: Int,
        fullW: Int, fullH: Int,
        transpose: Bool, mirrorX: Bool = false,
        thumbWidth: Int = 90, thumbHeight: Int = 160, scale: Int = 8
    ) -> Data? {
        let w = thumbWidth, h = thumbHeight
        let s = scale

        guard let context = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        guard let data = context.data else { return nil }
        let dst = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        yData.withUnsafeBytes { yRaw in
            cbcrData.withUnsafeBytes { cbcrRaw in
                let yPtr = yRaw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let cbcrPtr = cbcrRaw.baseAddress!.assumingMemoryBound(to: UInt8.self)

                for ty in 0..<h {
                    for tx in 0..<w {
                        let bufX: Int, bufY: Int
                        if transpose {
                            bufX = ty * s; bufY = tx * s
                        } else {
                            bufX = tx * s; bufY = ty * s
                        }

                        let C = Int(yPtr[bufY * yBpr + bufX]) - 16
                        let cbcrOff = (bufY / 2) * cbcrBpr + (bufX / 2) * 2
                        let D = Int(cbcrPtr[cbcrOff])     - 128
                        let E = Int(cbcrPtr[cbcrOff + 1]) - 128

                        var R = (298 * C + 409 * E + 128) >> 8
                        var G = (298 * C - 100 * D - 208 * E + 128) >> 8
                        var B = (298 * C + 516 * D + 128) >> 8
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
            }
        }

        guard let cgImage = context.makeImage() else { return nil }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cgImage,
            [kCGImageDestinationLossyCompressionQuality: 0.5] as CFDictionary)
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
            }

            if avgRun >= minSupport {
                return GateAnalysis(
                    hasQualifyingSlice: true,
                    detectionY: sumMid / sw,
                    maxVerticalRun: avgRun
                )
            }
        }

        guard overallBestAvg > 0 else { return nil }
        return GateAnalysis(
            hasQualifyingSlice: false,
            detectionY: overallBestMid,
            maxVerticalRun: overallBestAvg
        )
    }

    // MARK: - Logging

    private func logReject(_ reason: String, detail: String = "") {
        guard reason != lastRejectReason else { return }
        lastRejectReason = reason
        if detail.isEmpty {
            print("[REJECT] \(reason)")
        } else {
            print("[REJECT] \(reason) — \(detail)")
        }
    }
}
