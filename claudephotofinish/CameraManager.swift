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
    @Published var elapsedTime: TimeInterval = 0
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

    private var timerStart: Date?
    private var displayLink: Timer?
    private var frameCount: Int = 0

    // MARK: Init

    override init() {
        super.init()
        configureSession()
        startMotionTracking()
    }

    deinit {
        motionManager.stopDeviceMotionUpdates()
        displayLink?.invalidate()
    }

    // MARK: - Session

    private func configureSession() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1280x720

        addCamera(position: .back)

        // Use BGRA so we can create correct color thumbnails
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
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
        elapsedTime = 0
        frameCount = 0
        engine.isFrontCamera = (cameraPosition == .front)
        engine.start()
        isDetecting = true
        print("[SESSION] detection started, run #\(runNumber)")

        displayLink?.invalidate()
        displayLink = Timer.scheduledTimer(withTimeInterval: 1.0 / 100.0, repeats: true) { [weak self] _ in
            guard let self, let start = self.timerStart else { return }
            self.elapsedTime = Date().timeIntervalSince(start)
        }
    }

    func stopDetection() {
        engine.stop()
        isDetecting = false
        displayLink?.invalidate()
        print("[SESSION] detection stopped, \(crossings.count) crossings recorded")
    }

    func resetSession() {
        stopDetection()
        crossings = []
        elapsedTime = 0
        runNumber += 1
        engine.reset()
        print("[SESSION] reset, starting run #\(runNumber)")
    }

    // MARK: - Motion

    private func startMotionTracking() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
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
        var reason = "unknown"
        if let attachment = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil) {
            reason = attachment as! String
        }
        print("[FRAME_DROP] reason=\(reason) frame=\(frameCount)")
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard isDetecting, isPhoneStable else { return }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let expDur = currentInput?.device.exposureDuration
        frameCount += 1

        guard let result = engine.processFrame(pb, timestamp: ts, exposureDuration: expDur) else {
            return
        }

        // Beep on detection (dispatch off processing queue to avoid blocking)
        DispatchQueue.main.async { AudioServicesPlaySystemSound(1052) }

        // Generate thumbnail inline (90x160 is fast enough) to avoid
        // retaining CVPixelBuffer across queues, which causes OutOfBuffers drops
        let thumbData = DetectionEngine.colorThumbnail(
            from: pb, transpose: result.isLandscapeBuffer, mirrorX: engine.isFrontCamera
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let record = LapRecord(
                id: UUID(),
                crossingNumber: self.crossings.count + 1,
                time: result.crossingTime,
                thumbnailData: thumbData,
                gateY: result.gateY,
                componentBounds: result.componentBounds
            )
            self.crossings.append(record)
            print("[CROSSING] #\(record.crossingNumber) at \(String(format: "%.3f", record.time))s")
        }
    }
}
