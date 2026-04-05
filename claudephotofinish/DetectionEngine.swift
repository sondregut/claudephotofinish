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

    // Gate
    private var gateColumn: Int { processWidth / 2 }
    private let gateBandHalf: Int = 2

    // Session state
    private(set) var isActive = false
    var isFrontCamera = false
    private var sessionStart: CMTime?
    private var lastDetectionElapsed: TimeInterval?
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

        let fullW = CVPixelBufferGetWidth(pixelBuffer)
        let fullH = CVPixelBufferGetHeight(pixelBuffer)
        let bpr   = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        // BGRA buffers may arrive landscape despite videoRotationAngle=90
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

        // Cooldown
        let now = CMTimeGetSeconds(timestamp)
        let start = CMTimeGetSeconds(sessionStart!)
        let elapsed = now - start
        if let last = lastDetectionElapsed, (elapsed - last) < cooldown { return nil }

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

        var best: (comp: Component, detY: Int)?
        var candidateCount = 0

        for comp in components {
            if comp.height < minH {
                logReject("height", detail: "\(comp.height)/\(minH)")
                continue
            }
            if comp.width < minW {
                logReject("width", detail: "\(comp.width)/\(minW)")
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
                        best = (comp, analysis.detectionY)
                    }
                } else {
                    logReject("local_support",
                              detail: "run=\(analysis.maxVerticalRun) need=\(max(3, Int(Float(comp.height) * localSupportFraction)))")
                }
            }
        }

        guard let candidate = best else { return nil }

        // 6. Interpolate time
        let prevSec = CMTimeGetSeconds(previousTimestamp)
        var crossingTime = (now + prevSec) / 2.0 - start

        // Low-light exposure correction
        if let exp = exposureDuration ?? previousExposureDuration {
            let expSec = CMTimeGetSeconds(exp)
            if expSec > 0.002 { crossingTime += 0.75 * expSec }
        }

        lastDetectionElapsed = crossingTime
        lastRejectReason = ""

        let c = candidate.comp
        let hR = Float(c.height) / Float(H)
        let wR = Float(c.width) / Float(W)

        print(String(format: "[DETECT] blob=%dx%d hR=%.2f wR=%.2f cands=%d area=%d detY=%d frame=%d time=%.3f",
                     c.width, c.height, hR, wR, candidateCount, c.area, candidate.detY, frameIndex, crossingTime))

        // Thumbnail (color, from BGRA buffer)
        let thumbData = colorThumbnail(base: base, fullW: fullW, fullH: fullH, bpr: bpr,
                                       w: W, h: H, transpose: isLandscape,
                                       mirrorX: isFrontCamera)

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
            thumbnailData: thumbData
        )
    }

    // MARK: - Grayscale Extraction (from BGRA, with transpose support)

    private func extractGray(
        base: UnsafeMutableRawPointer, fullW: Int, fullH: Int, bpr: Int,
        w: Int, h: Int, transpose: Bool, into dest: inout [UInt8]
    ) {
        let src = base.assumingMemoryBound(to: UInt8.self)
        let s = scale

        if transpose {
            // Buffer is landscape (fullW > fullH), need to rotate 90 for portrait
            for ty in 0..<h {
                let bufX = ty * s
                for tx in 0..<w {
                    let bufY = tx * s
                    let px = bufY * bpr + bufX * 4
                    // BGRA: B=px, G=px+1, R=px+2
                    let gray = (Int(src[px + 2]) * 77 + Int(src[px + 1]) * 150 + Int(src[px]) * 29) >> 8
                    dest[ty * w + tx] = UInt8(gray)
                }
            }
        } else {
            // Buffer is already portrait
            for ty in 0..<h {
                let rowOff = ty * s * bpr
                for tx in 0..<w {
                    let px = rowOff + tx * s * 4
                    let gray = (Int(src[px + 2]) * 77 + Int(src[px + 1]) * 150 + Int(src[px]) * 29) >> 8
                    dest[ty * w + tx] = UInt8(gray)
                }
            }
        }
    }

    // MARK: - Color Thumbnail (from BGRA, matching reference project)

    private func colorThumbnail(
        base: UnsafeMutableRawPointer, fullW: Int, fullH: Int, bpr: Int,
        w: Int, h: Int, transpose: Bool, mirrorX: Bool = false
    ) -> Data? {
        let src = base.assumingMemoryBound(to: UInt8.self)
        let s = scale

        guard let context = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        guard let data = context.data else { return nil }
        let dst = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        if transpose {
            for ty in 0..<h {
                let bufX = ty * s
                for tx in 0..<w {
                    let bufY = tx * s
                    let sp = bufY * bpr + bufX * 4
                    let dx = mirrorX ? (w - 1 - tx) : tx
                    let dp = (ty * w + dx) * 4
                    dst[dp]     = src[sp + 2] // R
                    dst[dp + 1] = src[sp + 1] // G
                    dst[dp + 2] = src[sp]     // B
                    dst[dp + 3] = 255
                }
            }
        } else {
            for ty in 0..<h {
                let rowOff = ty * s * bpr
                for tx in 0..<w {
                    let sp = rowOff + tx * s * 4
                    let dx = mirrorX ? (w - 1 - tx) : tx
                    let dp = (ty * w + dx) * 4
                    dst[dp]     = src[sp + 2]
                    dst[dp + 1] = src[sp + 1]
                    dst[dp + 2] = src[sp]
                    dst[dp + 3] = 255
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

    // MARK: - Connected Components (8-way, union-find)

    private func findComponents() -> [Component] {
        let W = processWidth, H = processHeight
        let count = W * H

        for i in 0..<count { labels[i] = 0 }

        var nextLabel: Int32 = 1
        var parent = [Int32](repeating: 0, count: count / 4 + 256)

        func ensure(_ cap: Int) {
            if cap >= parent.count {
                parent.append(contentsOf: [Int32](repeating: 0, count: cap - parent.count + 256))
            }
        }

        func find(_ x: Int32) -> Int32 {
            var r = x
            while parent[Int(r)] != r { r = parent[Int(r)] }
            var c = x
            while c != r {
                let n = parent[Int(c)]
                parent[Int(c)] = r
                c = n
            }
            return r
        }

        func union(_ a: Int32, _ b: Int32) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[Int(ra)] = rb }
        }

        for y in 0..<H {
            for x in 0..<W {
                let idx = y * W + x
                guard maskBuf[idx] != 0 else { continue }

                var neighbors = [Int32]()
                if y > 0 && x > 0   { let l = labels[(y-1)*W+(x-1)]; if l > 0 { neighbors.append(l) } }
                if y > 0             { let l = labels[(y-1)*W+x];     if l > 0 { neighbors.append(l) } }
                if y > 0 && x < W-1 { let l = labels[(y-1)*W+(x+1)]; if l > 0 { neighbors.append(l) } }
                if x > 0             { let l = labels[y*W+(x-1)];     if l > 0 { neighbors.append(l) } }

                if neighbors.isEmpty {
                    let lbl = nextLabel
                    ensure(Int(lbl))
                    parent[Int(lbl)] = lbl
                    labels[idx] = lbl
                    nextLabel += 1
                } else {
                    let minL = neighbors.min()!
                    labels[idx] = minL
                    for n in neighbors { union(n, minL) }
                }
            }
        }

        var map = [Int32: Component]()

        for y in 0..<H {
            for x in 0..<W {
                let idx = y * W + x
                let lbl = labels[idx]
                guard lbl > 0 else { continue }
                let root = find(lbl)
                labels[idx] = root

                if map[root] == nil { map[root] = Component() }
                var c = map[root]!
                c.minX = min(c.minX, x)
                c.maxX = max(c.maxX, x)
                c.minY = min(c.minY, y)
                c.maxY = max(c.maxY, y)
                c.area += 1
                map[root] = c
            }
        }

        return Array(map.values)
    }

    // MARK: - Gate Analysis

    private func analyzeGate(comp: Component, gMin: Int, gMax: Int) -> GateAnalysis? {
        let W = processWidth
        var bestRun = 0
        var bestMid = 0

        for gx in gMin...gMax {
            guard gx >= 0, gx < W else { continue }
            var runStart = -1
            var runLen   = 0

            for y in comp.minY...comp.maxY {
                if maskBuf[y * W + gx] != 0 {
                    if runStart < 0 { runStart = y }
                    runLen += 1
                } else {
                    if runLen > bestRun {
                        bestRun = runLen
                        bestMid = runStart + runLen / 2
                    }
                    runStart = -1; runLen = 0
                }
            }
            if runLen > bestRun {
                bestRun = runLen
                bestMid = runStart + runLen / 2
            }
        }

        guard bestRun > 0 else { return nil }

        let minSupport = max(3, Int(Float(comp.height) * localSupportFraction))
        return GateAnalysis(
            hasQualifyingSlice: bestRun >= minSupport,
            detectionY: bestMid,
            maxVerticalRun: bestRun
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
