import Foundation
import AVFoundation
import AudioToolbox
import CoreMotion
import UIKit
import Combine

final class CameraManager: NSObject, ObservableObject {

    // MARK: Published state

    @Published var isSessionRunning = false
    @Published var isPhoneStable    = true
    @Published var isDetecting      = false
    @Published var cameraPosition: AVCaptureDevice.Position = .back
    @Published var crossings: [LapRecord] = []
    @Published private(set) var timerStart: Date? = nil
    /// Set when the user taps Stop. When non-nil, the timer UI freezes the
    /// elapsed display at `timerStop - timerStart` instead of ticking up
    /// against the wall clock. Cleared by `startDetection` and `resetSession`.
    @Published private(set) var timerStop: Date? = nil
    @Published var runNumber: Int = 1

    /// Engine-relative time of the first crossing in this session. Lap 1's
    /// stored `record.time` is normalized to 0.00 (so the first visible lap
    /// matches Photo Finish's Lap 1 = 00.00 convention) and `timerStart` is
    /// shifted forward by this amount so the on-screen timer also reads
    /// 00.00 at the moment Lap 1 fires. Reset by `startDetection` and
    /// `resetSession`.
    private var firstCrossingTime: TimeInterval? = nil

    // MARK: Camera tuning (exposed to the UI)
    //
    // Max shutter the *auto* exposure algo is allowed to pick. iOS session
    // presets silently clamp this to ~25 ms regardless of what you set, so
    // `configureSession` uses `setActiveFormat:` instead of a preset. Shorter
    // cap → sharper motion edges at the gate → less fat mask → better detY.
    // High ISO (noise) is cheap for our pipeline: frame-differencing with the
    // `diffThreshold=15` binary mask kills per-frame noise, and downstream
    // blob filters kill any speckles that do survive.
    /// Max shutter duration the auto-exposure algorithm is allowed to pick.
    /// `nil` means "use the active format's built-in default" (sets
    /// `activeMaxExposureDuration = .invalid`). PF paper §4.4: exposure
    /// ranges 0.5–33 ms with no cap — auto-exposure lands near ~1 ms in
    /// bright daylight on its own. Default to `nil` to match PF.
    @Published var maxExposureCapMs: Double? = nil {
        didSet { applyExposureSettings() }
    }
    @Published var isManualExposure: Bool = false {
        didSet { applyExposureSettings() }
    }
    @Published var manualExposureMs: Double = 4.0 {
        didSet { if isManualExposure { applyExposureSettings() } }
    }
    @Published var manualISO: Float = 400 {
        didSet { if isManualExposure { applyExposureSettings() } }
    }

    // §12.5 A/B picker toggle — mirrored from engine so the tuning panel can bind to it
    @Published var pickerMode: PickerMode = .longestRun {
        didSet {
            engine.pickerMode = pickerMode
            guard oldValue != pickerMode else { return }
            slog("[CONFIG] pickerMode=\(pickerMode.rawValue) (was \(oldValue.rawValue))")
        }
    }
    @Published var absolutePickerFloor: Int = 160 {
        didSet {
            engine.absolutePickerFloor = absolutePickerFloor
            guard oldValue != absolutePickerFloor else { return }
            slog("[CONFIG] absolutePickerFloor=\(absolutePickerFloor) (was \(oldValue))")
        }
    }

    // Live readouts sampled from the capture queue. Updated ~once/sec to avoid
    // thrashing SwiftUI on the main thread.
    @Published var currentExposureMs: Double = 0
    @Published var currentISO: Float = 0

    // MARK: Camera

    let captureSession = AVCaptureSession()
    private var currentInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let processingQueue = DispatchQueue(
        label: "com.claudephotofinish.videoProcessing",
        qos: .userInitiated
    )

    // MARK: Detection

    let engine = DetectionEngine()

    // MARK: Motion

    private let motionManager = CMMotionManager()
    private let motionThreshold: Double = 0.15
    private var stableTimer: Timer?

    // MARK: Timer

    private var frameCount: Int = 0
    private var droppedFrameCount: Int = 0
    private var previousPlaneCopy: YUVPlaneCopy?
    // [CAM] log de-spam: only print when exposure/iso/cap actually change.
    private var lastLoggedExpMs: Double = -1
    private var lastLoggedISO: Float = -1
    private var lastLoggedCapMs: Double = -1
    // [GAP] stall measurement: wall-clock time of last captureOutput entry.
    private var lastCaptureWallTime: CFAbsoluteTime = 0

    // MARK: Init

    override init() {
        super.init()
        configureSession()
        startMotionTracking()
        // Re-apply exposure settings when the capture session recovers
        // from an interruption (app backgrounding, Siri, incoming call,
        // another app taking the camera). iOS resets
        // `device.activeMaxExposureDuration` across session interruption
        // but our code only wrote it once in `configureSession`. Without
        // this observer, resuming the app silently drops back to the
        // format's default exposure cap and the "use iOS default" toggle
        // in the UI becomes a lie until the user flips it off/on.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionInterruptionEnded),
            name: .AVCaptureSessionInterruptionEnded,
            object: captureSession
        )
    }

    deinit {
        motionManager.stopDeviceMotionUpdates()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleSessionInterruptionEnded(_ note: Notification) {
        slog("[CAMERA_CFG] interruption ended, reapplying exposure")
        engine.resetWarmup()
        processingQueue.async { [weak self] in
            self?.applyExposureSettings()
            DispatchQueue.main.async { self?.logCurrentConfig() }
        }
    }

    // MARK: - Session

    private func configureSession() {
        captureSession.beginConfiguration()
        // NOTE: intentionally no `sessionPreset`. Session presets silently
        // clamp `activeMaxExposureDuration` to ~25 ms, which is what was
        // producing the motion blur we saw in Test B / Test C thumbnails.
        // Picking the format manually via `setActiveFormat:` lifts that clamp
        // and lets us cap the auto-exposure shutter at something much shorter.
        // When you set `activeFormat` on a device in a session, the session
        // switches to `.inputPriority` automatically.

        addCamera(position: .back)

        // 420v: native camera format, video-range Y [16-235] for detection, CbCr for color thumbnails
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)

        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        // Request portrait orientation + disable stabilization
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            connection.preferredVideoStabilizationMode = .off
        }

        applyCameraFormat()
        captureSession.commitConfiguration()
    }

    private func addCamera(position: AVCaptureDevice.Position) {
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: position
        ) else { return }

        // Disable Center Stage on devices that support it — it crops/pans the frame
        if #available(iOS 16.0, *), AVCaptureDevice.isCenterStageEnabled {
            AVCaptureDevice.centerStageControlMode = .cooperative
            AVCaptureDevice.isCenterStageEnabled = false
        }

        guard let input = try? AVCaptureDeviceInput(device: device) else { return }

        if let old = currentInput {
            captureSession.removeInput(old)
        }
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
            currentInput = input
            cameraPosition = position
        }
    }

    /// Pick a 1280×720 @ 30 fps 420v format explicitly (bypasses session-preset
    /// clamps on `activeMaxExposureDuration`), lock frame rate, then apply the
    /// current exposure settings. Called from `configureSession` and on every
    /// camera switch.
    private func applyCameraFormat() {
        guard let device = currentInput?.device else { return }
        try? device.lockForConfiguration()

        // Find a 1280×720 @ 30 fps 420v format. Fall back to any 1280×720 @ 30
        // format if the exact pixel-format match is missing on this device.
        let wanted420v = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let candidates = device.formats.filter { fmt in
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            guard dims.width == 1280 && dims.height == 720 else { return false }
            let supports30 = fmt.videoSupportedFrameRateRanges.contains { r in
                r.minFrameRate <= 30 && r.maxFrameRate >= 30
            }
            return supports30
        }

        // DIAG: dump every candidate 1280×720 format so we can see whether
        // any of them natively has a shorter `maxExposureDuration` than the
        // default `.hd1280x720` preset. Photo Finish might be achieving its
        // sharpness by picking a high-frame-rate-capable format (where the
        // sensor's max integration time is natively short) rather than by
        // setting `activeMaxExposureDuration` explicitly.
        slog("[FORMAT_DUMP] available 1280x720 formats (\(candidates.count)):")
        for (i, fmt) in candidates.enumerated() {
            let sub = CMFormatDescriptionGetMediaSubType(fmt.formatDescription)
            let subStr = String(format: "%c%c%c%c",
                                (sub >> 24) & 0xff, (sub >> 16) & 0xff,
                                (sub >> 8) & 0xff, sub & 0xff)
            let fpsRanges = fmt.videoSupportedFrameRateRanges.map {
                String(format: "%.0f-%.0f", $0.minFrameRate, $0.maxFrameRate)
            }.joined(separator: ",")
            let minMs = CMTimeGetSeconds(fmt.minExposureDuration) * 1000
            let maxMs = CMTimeGetSeconds(fmt.maxExposureDuration) * 1000
            slog(String(
                format: "[FORMAT_DUMP]  #%d subtype=%@ fps=[%@] exp=%.3f..%.1fms iso=%.0f..%.0f binned=%@ hiRes=%@",
                i, subStr, fpsRanges, minMs, maxMs, fmt.minISO, fmt.maxISO,
                fmt.isVideoBinned ? "Y" : "n",
                fmt.isHighPhotoQualitySupported ? "Y" : "n"
            ))
        }

        let target = candidates.first { fmt in
            CMFormatDescriptionGetMediaSubType(fmt.formatDescription) == wanted420v
        } ?? candidates.first

        if let fmt = target {
            device.activeFormat = fmt
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let minExpMs = CMTimeGetSeconds(fmt.minExposureDuration) * 1000
            let maxExpMs = CMTimeGetSeconds(fmt.maxExposureDuration) * 1000
            slog(String(
                format: "[CAMERA_CFG] format=%dx%d exposureRange=%.2f..%.2fms isoRange=%.0f..%.0f",
                dims.width, dims.height,
                minExpMs, maxExpMs,
                fmt.minISO, fmt.maxISO
            ))
        } else {
            slog("[CAMERA_CFG] WARNING: no 1280x720@30 format found, using device default")
        }

        // Lock frame rate
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)

        device.unlockForConfiguration()

        // Apply exposure cap / manual mode on top of the new format.
        applyExposureSettings()
    }

    /// Configure auto-exposure cap or fully-manual exposure per the
    /// `maxExposureCapMs` / `isManualExposure` / `manualExposureMs` /
    /// `manualISO` published properties. Safe to call from the UI thread —
    /// device locking is cheap and only happens on property change.
    private func applyExposureSettings() {
        guard let device = currentInput?.device else { return }

        do {
            try device.lockForConfiguration()
        } catch {
            slog("[CAMERA_CFG] lockForConfiguration failed: \(error)")
            return
        }
        defer { device.unlockForConfiguration() }

        let fmt = device.activeFormat
        let fmtMinExp = CMTimeGetSeconds(fmt.minExposureDuration)
        let fmtMaxExp = CMTimeGetSeconds(fmt.maxExposureDuration)
        let fmtMinISO = fmt.minISO
        let fmtMaxISO = fmt.maxISO

        if isManualExposure {
            // Fully manual. Clamp to whatever the active format supports.
            let expSec = min(max(manualExposureMs / 1000.0, fmtMinExp), fmtMaxExp)
            let iso = min(max(manualISO, fmtMinISO), fmtMaxISO)
            let expCM = CMTimeMakeWithSeconds(expSec, preferredTimescale: 1_000_000)
            device.setExposureModeCustom(duration: expCM, iso: iso) { _ in }
            slog(String(
                format: "[CAMERA_CFG] mode=MANUAL exp=%.2fms iso=%.0f",
                expSec * 1000, iso
            ))
        } else if let capMs = maxExposureCapMs {
            // Auto with a shutter cap. Keeps Photo-Finish-style adaptation
            // (auto-ISO, adaptive) but prevents the shutter from going longer
            // than the cap.
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            let capSec = min(max(capMs / 1000.0, fmtMinExp), fmtMaxExp)
            let capCM = CMTimeMakeWithSeconds(capSec, preferredTimescale: 1_000_000)
            device.activeMaxExposureDuration = capCM
            slog(String(
                format: "[CAMERA_CFG] mode=AUTO maxExp=%.2fms (requested=%.2fms, fmt range %.2f..%.2fms)",
                capSec * 1000, capMs, fmtMinExp * 1000, fmtMaxExp * 1000
            ))
        } else {
            // iOS default — no cap override. This is the baseline test: what
            // does the active format pick on its own? If the format still
            // clamps to 25 ms, `setActiveFormat` alone isn't enough and the
            // cap is mandatory.
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.activeMaxExposureDuration = .invalid
            slog("[CAMERA_CFG] mode=AUTO maxExp=<iOS default for format>")
        }
    }

    func startSession() {
        processingQueue.async { [weak self] in
            self?.captureSession.startRunning()
            DispatchQueue.main.async { self?.isSessionRunning = true }
        }
        // Warm the vImage thumbnail pipeline on the same queue the real
        // per-crossing thumbnail work uses, so first-touch JIT/page-in
        // happens long before any user can tap Start. Without this the
        // first crossing drops ~17 capture frames.
        DispatchQueue.global(qos: .utility).async {
            DetectionEngine.prewarmThumbnail()
        }
    }

    func stopSession() {
        captureSession.stopRunning()
        isSessionRunning = false
    }

    // MARK: - Camera Switch

    func switchCamera() {
        let next: AVCaptureDevice.Position = cameraPosition == .back ? .front : .back
        captureSession.beginConfiguration()
        addCamera(position: next)

        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            connection.preferredVideoStabilizationMode = .off
            if next == .front {
                connection.isVideoMirrored = true
            }
        }

        applyCameraFormat()
        captureSession.commitConfiguration()
        engine.isFrontCamera = (next == .front)
        slog("[CAMERA] switched to \(next == .front ? "front" : "back")")
        logCurrentConfig()
    }

    // MARK: - Detection Control

    func startDetection() {
        crossings = []
        timerStart = Date()
        timerStop = nil
        firstCrossingTime = nil
        frameCount = 0
        droppedFrameCount = 0   // discard idle-period drops
        lastCaptureWallTime = 0 // start [GAP] measurement fresh
        previousPlaneCopy = nil
        engine.isFrontCamera = (cameraPosition == .front)
        engine.start()
        isDetecting = true
        // Open a fresh on-disk session file BEFORE the first slog so every
        // line below (including [SESSION] and [CONFIG]) lands in the file.
        SessionLogger.shared.startSession()
        slog("[SESSION] detection started, run #\(runNumber)")
        logCurrentConfig()
    }

    /// Emit a single `[CONFIG]` line with every user-tunable mode/setting that
    /// affects a test run: camera position, exposure mode, picker mode, and
    /// the live shutter/ISO sampled from the device. Called at the start of
    /// each detection session and on camera switch so log buffers copied out
    /// via the tuning panel are fully self-describing.
    func logCurrentConfig() {
        let pickerDesc: String
        switch pickerMode {
        case .longestRun:    pickerDesc = "longestRun"
        case .topThird:      pickerDesc = "topThird"
        case .absoluteFloor: pickerDesc = "floor\(absolutePickerFloor)"
        }

        // Sample the device directly rather than trusting the ~1Hz
        // @Published readouts, which may be stale at session start.
        var liveExpMs: Double = -1
        var liveISO: Float = -1
        var capMs: Double = -1
        var fmtStr = "unknown"
        if let device = currentInput?.device {
            liveExpMs = CMTimeGetSeconds(device.exposureDuration) * 1000
            liveISO = device.iso
            let cap = device.activeMaxExposureDuration
            capMs = CMTIME_IS_VALID(cap) ? CMTimeGetSeconds(cap) * 1000 : -1
            let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            fmtStr = "\(dims.width)x\(dims.height)"
        }

        let expMode: String
        if isManualExposure {
            expMode = String(format: "MANUAL(%.2fms,iso%.0f)", manualExposureMs, manualISO)
        } else if let req = maxExposureCapMs {
            expMode = String(format: "AUTO(cap=%.2fms)", req)
        } else {
            expMode = "AUTO(default)"
        }

        slog(String(format:
            "[CONFIG] run=%d cam=%@ format=%@ expMode=%@ liveExp=%.2fms liveISO=%.0f activeCap=%.2fms picker=%@ detecting=%@",
            runNumber, cameraPosition == .front ? "front" : "back",
            fmtStr, expMode, liveExpMs, liveISO, capMs, pickerDesc,
            isDetecting ? "YES" : "no"
        ))
    }

    func stopDetection() {
        engine.stop()
        isDetecting = false
        // Freeze the timer UI at the moment Stop was tapped. Without this
        // the TimelineView in ContentView keeps ticking against a live
        // `timerStart` even though detection is off.
        if timerStart != nil { timerStop = Date() }
        slog("[SESSION] detection stopped, \(crossings.count) crossings recorded")
        // Close the on-disk session file AFTER the final [SESSION] line so
        // the stop marker is captured in the file.
        SessionLogger.shared.endSession()
    }

    func resetSession() {
        stopDetection()
        crossings = []
        timerStart = nil
        timerStop = nil
        firstCrossingTime = nil
        runNumber += 1
        engine.reset()
        slog("[SESSION] reset, starting run #\(runNumber)")
    }

    /// Update a lap's ground-truth mark. `point` is in the 180×320 source
    /// coordinate space (same as `DetectionEngine.processWidth/Height`).
    func markLapPoint(id: UUID, point: CGPoint) {
        guard let idx = crossings.firstIndex(where: { $0.id == id }) else { return }
        let lap = crossings[idx]
        crossings[idx].userMarkedPoint = point
        let ux = Int(point.x.rounded())
        let uy = Int(point.y.rounded())
        let dy = uy - lap.gateY
        slog(String(
            format: "[USER_MARK] #%d detY=%d userY=%d Δy=%+d userX=%d time=%.3f",
            lap.crossingNumber, lap.gateY, uy, dy, ux, lap.time
        ))
    }

    // MARK: - Motion

    private func startMotionTracking() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 10.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let m = motion else { return }
            let a = m.userAcceleration
            let mag = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)

            if mag > self.motionThreshold {
                self.isPhoneStable = false
                self.stableTimer?.invalidate()
                self.stableTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: false) { _ in
                    self.isPhoneStable = true
                }
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Count drops silently — logging each one on the serial processing queue
        // creates a cascade where the log I/O keeps the queue busy, causing more drops.
        droppedFrameCount += 1
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Telemetry runs on every frame regardless of detection state so we
        // can see what iOS is picking in idle (before any run starts). Only
        // the detection pipeline itself is gated on `isDetecting`.
        frameCount += 1
        let expDur = currentInput?.device.exposureDuration
        let isoVal = currentInput?.device.iso

        // Wall-clock gap measurement. Only log gaps > 50ms (>1 frame skipped)
        // to find where on the timeline the pipeline stalls. Tells us whether
        // a stall is on processingQueue or upstream of us.
        let nowWall = CFAbsoluteTimeGetCurrent()
        if lastCaptureWallTime > 0 {
            let gapMs = (nowWall - lastCaptureWallTime) * 1000
            if gapMs > 50 {
                slog(String(format: "[GAP] %.0fms gap before frame=%d", gapMs, frameCount))
            }
        }
        lastCaptureWallTime = nowWall

        // Camera state log: only fires when exposure / iso / cap actually
        // changes (rounded to 0.1ms / 1 ISO / 0.1ms). Sampled at most ~1 Hz.
        if frameCount % 30 == 0, let exp = expDur, let iso = isoVal {
            let expMs = CMTimeGetSeconds(exp) * 1000
            let capMs: Double
            if let device = currentInput?.device {
                let cap = device.activeMaxExposureDuration
                capMs = CMTIME_IS_VALID(cap) ? CMTimeGetSeconds(cap) * 1000 : -1
            } else {
                capMs = -1
            }
            let expChanged = abs(expMs - lastLoggedExpMs) >= 0.1
            let isoChanged = abs(iso - lastLoggedISO) >= 1
            let capChanged = abs(capMs - lastLoggedCapMs) >= 0.1
            if expChanged || isoChanged || capChanged {
                slog(String(
                    format: "[CAM] exp=%.2fms iso=%.0f cap=%.2fms frame=%d detecting=%@",
                    expMs, iso, capMs, frameCount, isDetecting ? "YES" : "no"
                ))
                lastLoggedExpMs = expMs
                lastLoggedISO = iso
                lastLoggedCapMs = capMs
            }
            DispatchQueue.main.async { [weak self] in
                self?.currentExposureMs = expMs
                self?.currentISO = iso
            }
        }

        guard isDetecting, isPhoneStable else { return }

        // Log accumulated frame drops as a single summary
        if droppedFrameCount > 0 {
            slog("[FRAME_DROP] \(droppedFrameCount) frames dropped since frame \(frameCount)")
            droppedFrameCount = 0
        }

        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Copy current frame's YUV planes before processing result —
        // we need this both for the thumbnail and to keep as "previous" for next frame.
        let currentPlaneCopy = Self.copyYUVPlanes(from: pb)

        guard let result = engine.processFrame(
            pb, timestamp: ts,
            exposureDuration: expDur, iso: isoVal
        ) else {
            previousPlaneCopy = currentPlaneCopy
            return
        }

        // Beep on detection (vibration disabled)
        // DispatchQueue.main.async { AudioServicesPlaySystemSound(1052) }

        // Pick the frame closest to the actual gate crossing.
        // fraction < 0.5 → body was closer to gate in frame N-1 (previous frame)
        // fraction >= 0.5 → body is closer to gate in frame N (current frame)
        let isFront = engine.isFrontCamera
        let isLandscape = result.isLandscapeBuffer
        let usePrevious = result.interpolationFraction < 0.5 && previousPlaneCopy != nil
        let chosenPlanes = usePrevious ? previousPlaneCopy : currentPlaneCopy
        let frameLabel = usePrevious ? "prev (N-1)" : "curr (N)"
        slog(String(format: "[THUMBNAIL] using %@ frame (fraction=%.2f)", frameLabel, result.interpolationFraction))

        previousPlaneCopy = currentPlaneCopy

        DispatchQueue.global(qos: .utility).async {
            var thumbData: Data? = nil
            if let planes = chosenPlanes {
                thumbData = DetectionEngine.colorThumbnailFromPlanes(
                    yData: planes.yData, yBpr: planes.yBpr,
                    cbcrData: planes.cbcrData, cbcrBpr: planes.cbcrBpr,
                    fullW: planes.width, fullH: planes.height,
                    transpose: isLandscape, mirrorX: isFront
                )
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Normalize times so Lap 1 = 00.00, matching Photo Finish's
                // convention and making PF-parity comparisons a straight
                // subtraction (no +6.258 s manual offset).
                let adjustedTime: TimeInterval
                if self.firstCrossingTime == nil {
                    self.firstCrossingTime = result.crossingTime
                    adjustedTime = 0
                    if let ts = self.timerStart {
                        self.timerStart = ts.addingTimeInterval(result.crossingTime)
                    }
                } else {
                    adjustedTime = result.crossingTime - (self.firstCrossingTime ?? 0)
                }
                let record = LapRecord(
                    id: UUID(),
                    crossingNumber: self.crossings.count + 1,
                    time: adjustedTime,
                    thumbnailData: thumbData,
                    gateY: result.gateY,
                    rawGateY: result.rawGateY,
                    triggerHRun: result.triggerHRun,
                    triggerBandRows: result.triggerBandRows,
                    componentBounds: result.componentBounds,
                    interpolationFraction: result.interpolationFraction,
                    dBefore: result.dBefore,
                    dAfter: result.dAfter,
                    direction: result.movingLeftToRight ? "L>R" : "R>L",
                    usedPreviousFrame: usePrevious,
                    isFrontCamera: isFront,
                    userMarkedPoint: nil
                )
                self.crossings.append(record)
                AudioServicesPlaySystemSound(1052)
                slog("[CROSSING] #\(record.crossingNumber) at \(String(format: "%.3f", record.time))s")
            }
        }
    }

    // MARK: - YUV Plane Copy

    struct YUVPlaneCopy {
        let yData: Data
        let yBpr: Int
        let cbcrData: Data
        let cbcrBpr: Int
        let width: Int
        let height: Int
    }

    /// Copy Y and CbCr plane bytes so thumbnail can be generated on another queue
    /// without retaining the CVPixelBuffer (which would stall the capture pipeline).
    static func copyYUVPlanes(from pb: CVPixelBuffer) -> YUVPlaneCopy? {
        guard CVPixelBufferGetPlaneCount(pb) >= 2 else { return nil }

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        let yBpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let yH   = CVPixelBufferGetHeightOfPlane(pb, 0)
        let yW   = CVPixelBufferGetWidthOfPlane(pb, 0)
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let yData = Data(bytes: yBase, count: yBpr * yH)

        let cbcrBpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let cbcrH   = CVPixelBufferGetHeightOfPlane(pb, 1)
        guard let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }
        let cbcrData = Data(bytes: cbcrBase, count: cbcrBpr * cbcrH)

        return YUVPlaneCopy(
            yData: yData, yBpr: yBpr,
            cbcrData: cbcrData, cbcrBpr: cbcrBpr,
            width: yW, height: yH
        )
    }
}
