# Research 04: iPhone / Swift Camera Pipeline Constraints

This note focuses on what AVFoundation and the iPhone camera pipeline can do to a measurement detector even before your own logic runs.

## Core Capture Path for a Detector

For a Swift implementation, the relevant path is:

1. `AVCaptureSession`
2. rear camera `AVCaptureDevice`
3. `AVCaptureVideoDataOutput`
4. `captureOutput(_:didOutput:from:)`
5. `CMSampleBuffer` and `CVPixelBuffer`
6. per-frame processing on a serial queue

If the detector is the product, `AVCaptureVideoDataOutput` is the right output type because it gives direct access to frames.

## The Biggest AVFoundation Constraint: Real-Time Delivery

Apple is explicit here:

- your sample-buffer delegate has to finish inside the time budget of a frame
- if you process too slowly, AVFoundation can stop delivering frames or start dropping them

TN2445 is especially important for this project because it says:

- always set `alwaysDiscardsLateVideoFrames = YES` for real-time processing
- dropped frames can be observed in `captureOutput(_:didDrop:from:)`
- frame drops can be mitigated by lowering the frame rate dynamically

For a timing clone, this means:

- if your implementation is not comfortably real-time, you can create fake detector behavior that looks like the app but is actually just your pipeline dropping frames

## Timestamps and Timing

The detector should treat sample-buffer timestamps as part of the measurement path, not as logging detail.

Practical implication:

- interpolation accuracy depends on not silently dropping or reordering frames
- any dropped-frame event needs to be visible to the timing layer
- if you later model low-light correction, the camera's exposure duration becomes relevant too

Apple's `exposureDuration` API exposes the capture-device exposure time directly as a `CMTime`.

## Frame-Rate Control Is Not Optional

If you want clone-like behavior, you need to know whether the device is actually running at a stable frame rate.

AVFoundation exposes:

- supported frame-rate ranges through the active format
- `activeVideoMinFrameDuration`
- `activeVideoMaxFrameDuration`
- `isAutoVideoFrameRateEnabled`

If you leave frame rate too automatic, the phone can change temporal behavior underneath the detector.

That matters because your current evidence already treats 30 fps sampling as part of the app's behavior.

## Camera Features That Can Quietly Distort Geometry

Several iPhone camera features are bad defaults for a measurement app unless you intentionally want them:

- video stabilization
- Center Stage / smart framing
- portrait effects
- automatic frame-rate changes
- virtual-device switching on multi-camera phones

Why this matters:

- stabilization can shift geometry and add latency
- smart framing and virtual switching can change crop/focal behavior
- automatic frame-rate changes alter the detector's temporal sampling

For a measurement clone, the conservative starting assumption is:

- use a single rear wide camera
- avoid multi-camera virtual switching where possible
- avoid dynamic framing features
- keep the processing frame rate stable

## Suggested Swift Processing Stack

Use the cheapest path first:

- request the rear wide camera
- choose a format that can run at the target frame rate
- lock configuration before changing capture properties
- use `AVCaptureVideoDataOutput`
- process the luma plane directly from `CVPixelBuffer`
- do not convert every frame to `UIImage`
- keep processing on a dedicated serial queue

For compute:

- CPU + Accelerate/vImage is enough for a first prototype
- Metal becomes attractive if you add multi-frame accumulation or heavier morphology

## Why This Research Matters to the Photo Finish Clone

Several of your unresolved behaviors can be polluted by capture settings alone:

- dropped frames can mimic "super-fast invisible" misses
- automatic frame-rate changes can change interpolation behavior
- stabilization or virtual switching can move the effective gate geometry
- exposure duration affects blur and any low-light time correction

If you do not lock down the camera pipeline, you will not know whether a mismatch belongs to your detector or the capture stack.

## Sources

- Apple AVFoundation Programming Guide, "Still and Video Media Capture": [archive](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/AVFoundationPG/Articles/04_MediaCapture.html)
- Apple Technical Note TN2445, "Handling Frame Drops with AVCaptureVideoDataOutput": [archive](https://developer.apple.com/library/archive/technotes/tn2445/_index.html)
- Apple `AVCaptureDevice` overview and configuration topics: [docs](https://developer.apple.com/documentation/avfoundation/avcapturedevice)
- Apple `exposureDuration`: [docs](https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposureduration)
- Apple `activeVideoMinFrameDuration`: [docs](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activevideominframeduration)
- Apple `preferredVideoStabilizationMode`: [docs](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/preferredvideostabilizationmode)
- Apple `AVCam` sample overview: [docs](https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app)
