# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an iOS app (Swift/SwiftUI) that reverse-engineers the **Photo Finish** sprint-timing app's detection algorithm. We don't have Photo Finish's source code — everything is inferred from physical testing, screenshots, and an academic paper. The goal is to replicate its gate-crossing detection behavior as accurately as possible.

**Phase 1 = detector only.** UI, export, multi-phone sync, and polish are out of scope.

## Build & Run

- **Xcode project:** `claudephotofinish.xcodeproj` (no SPM, no CocoaPods)
- **Target:** iOS 17+, Swift 5
- **Build:** `xcodebuild -project claudephotofinish.xcodeproj -scheme claudephotofinish -destination 'platform=iOS,name=<device>'`
- **No tests or linting** configured — validation is done by physical testing on-device
- Requires a physical iPhone (camera access) — Simulator won't produce real frames

## Architecture

Six Swift files, no external dependencies:

- **`DetectionEngine.swift`** — Core detection pipeline. Processes Y-plane luma at 180×320 downsampled resolution. Pipeline: frame differencing → binary threshold → 8-way connected components (union-find) → size/fill/aspect prefilters → gate-band intersection → leading-edge local-support scoring → body-part suppression → position-based sub-frame interpolation → low-light exposure correction. This is where nearly all algorithmic work happens.

- **`CameraManager.swift`** — AVCaptureSession setup (720p, 30fps locked, YUV 420v biplanar, stabilization off, Center Stage off). Owns the `DetectionEngine`, drives frame processing on a serial queue, copies YUV planes for thumbnails, picks closest frame (N or N-1) based on interpolation fraction.

- **`ContentView.swift`** — SwiftUI UI: live timer, camera preview with gate line overlay, scrollable lap list with thumbnails, start/stop/reset/camera-switch controls.

- **`CameraPreviewView.swift`** — UIViewRepresentable wrapping `AVCaptureVideoPreviewLayer`.

- **`LapRecord.swift`** — Data struct for a single crossing (time, thumbnail, interpolation data, direction).

- **`claudephotofinishApp.swift`** — App entry point.

## Key Detection Parameters (DetectionEngine)

| Parameter | Value | Purpose |
|---|---|---|
| `processWidth/Height` | 180×320 | Downsampled working resolution (portrait) |
| `diffThreshold` | 15 | Luma delta to count as motion |
| `heightFraction` | 0.33 | Min blob height as fraction of frame |
| `widthFraction` | 0.08 | Min blob width as fraction of frame |
| `localSupportFraction` | 0.25 | Min vertical run at gate as fraction of blob height |
| `minFillRatio` | 0.25 | Reject sparse blobs (hand swipes) |
| `maxAspectRatio` | 1.2 | Reject wide-flat blobs |
| `cooldown` | 0.5s | Min time between detections |
| `warmupFrames` | 10 | Skip frames while auto-exposure settles |
| `gateBandHalf` | 2 | Gate is center column ±2 pixels |

## Reference Documents

- **`project_instructions.md`** — Working principles, current detector model, documentation rules, high-value unknowns
- **`detection_spec.md`** — Build-facing working spec (confirmed vs inferred behaviors)
- **`detection_inferences.md`** — Evidence → inference → confidence ledger
- **`pipeline_audit.md`** — Implementation vs spec comparison with open issues
- **`test_runs_our_detector.md`** — Raw run logs from physical testing of our reverse-engineered detector. Each run section pairs the exact algorithm/parameter state at the time with observed results (crossings, rejects, GATE_DIAG close-misses, USER_MARK Δy). Append a new "Run YYYY-MM-DD Test X" section here whenever new physical-test data comes in; mark hand-swipe vs real-body runs explicitly.
- **`PhotoFinish_Accuracy_Paper.pdf`** — Academic paper (Android-focused, not ground truth for iPhone)
- **`notes_*.md`** — CV research notes (frame differencing, background subtraction, blob geometry, iOS camera pipeline)

## Working Principles

- **Pure geometry is the leading theory** — torso-like detection behavior is treated as emergent from blob geometry, not a semantic body detector
- Prefer a precise unknown over a false certainty
- Don't add body-pose estimation, explicit torso classifiers, or heavy background subtraction
- When new evidence appears: update raw log → update spec → update inferences (keep layers separate)
- Camera must use `.hd1280x720` preset (not `.high`) — scale=6 at 1080p drops thin motion edges and breaks detection
