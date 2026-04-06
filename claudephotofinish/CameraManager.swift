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
    @Published var runNumber: Int = 1

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

    // MARK: Init

    override init() {
        super.init()
        configureSession()
        startMotionTracking()
    }

    deinit {
        motionManager.stopDeviceMotionUpdates()
    }

    // MARK: - Session

    private func configureSession() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1280x720

        addCamera(position: .back)

        // 420v: native Y plane for grayscale detection, CbCr for color thumbnails
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)

        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        // Request portrait orientation
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }

        lockFrameRate()
        captureSession.commitConfiguration()
    }

    private func addCamera(position: AVCaptureDevice.Position) {
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: position
        ) else { return }

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

    private func lockFrameRate() {
        guard let device = currentInput?.device else { return }
        try? device.lockForConfiguration()
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        device.unlockForConfiguration()
    }

    func startSession() {
        processingQueue.async { [weak self] in
            self?.captureSession.startRunning()
            DispatchQueue.main.async { self?.isSessionRunning = true }
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
            if next == .front {
                connection.isVideoMirrored = true
            }
        }

        lockFrameRate()
        captureSession.commitConfiguration()
        engine.isFrontCamera = (next == .front)
        print("[CAMERA] switched to \(next == .front ? "front" : "back")")
    }

    // MARK: - Detection Control

    func startDetection() {
        crossings = []
        timerStart = Date()
        frameCount = 0
        previousPlaneCopy = nil
        engine.isFrontCamera = (cameraPosition == .front)
        engine.start()
        isDetecting = true
        print("[SESSION] detection started, run #\(runNumber)")

        // Pre-warm CGContext + JPEG encoder on background thread
        // to eliminate first-detection cold start frame drops
        processingQueue.async { DetectionEngine.prewarmThumbnail() }
    }

    func stopDetection() {
        engine.stop()
        isDetecting = false
        print("[SESSION] detection stopped, \(crossings.count) crossings recorded")
    }

    func resetSession() {
        stopDetection()
        crossings = []
        timerStart = nil
        runNumber += 1
        engine.reset()
        print("[SESSION] reset, starting run #\(runNumber)")
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
        guard isDetecting, isPhoneStable else { return }

        // Log accumulated frame drops as a single summary
        if droppedFrameCount > 0 {
            print("[FRAME_DROP] \(droppedFrameCount) frames dropped since frame \(frameCount)")
            droppedFrameCount = 0
        }

        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let expDur = currentInput?.device.exposureDuration
        frameCount += 1

        // Copy current frame's YUV planes before processing result —
        // we need this both for the thumbnail and to keep as "previous" for next frame.
        let currentPlaneCopy = Self.copyYUVPlanes(from: pb)

        guard let result = engine.processFrame(pb, timestamp: ts, exposureDuration: expDur) else {
            previousPlaneCopy = currentPlaneCopy
            return
        }

        // Beep on detection (dispatch off processing queue to avoid blocking)
        DispatchQueue.main.async { AudioServicesPlaySystemSound(1052) }

        // Pick the frame closest to the actual gate crossing.
        // fraction < 0.5 → body was closer to gate in frame N-1 (previous frame)
        // fraction >= 0.5 → body is closer to gate in frame N (current frame)
        let isFront = engine.isFrontCamera
        let isLandscape = result.isLandscapeBuffer
        let usePrevious = result.interpolationFraction < 0.5 && previousPlaneCopy != nil
        let chosenPlanes = usePrevious ? previousPlaneCopy : currentPlaneCopy
        let frameLabel = usePrevious ? "prev (N-1)" : "curr (N)"
        print(String(format: "[THUMBNAIL] using %@ frame (fraction=%.2f)", frameLabel, result.interpolationFraction))

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
                let record = LapRecord(
                    id: UUID(),
                    crossingNumber: self.crossings.count + 1,
                    time: result.crossingTime,
                    thumbnailData: thumbData,
                    gateY: result.gateY,
                    componentBounds: result.componentBounds,
                    interpolationFraction: result.interpolationFraction,
                    dBefore: result.dBefore,
                    dAfter: result.dAfter,
                    direction: result.movingLeftToRight ? "L>R" : "R>L",
                    usedPreviousFrame: usePrevious
                )
                self.crossings.append(record)
                print("[CROSSING] #\(record.crossingNumber) at \(String(format: "%.3f", record.time))s")
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
