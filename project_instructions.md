# CLAUDE.md

## Project

This folder is for reverse engineering the **Photo Finish** sprint-timing app's **detection algorithm** as accurately as possible.

Current target:

- **iPhone**
- **Swift**
- **Phase 1 = detector only**

Out of scope for now:

- UI
- export UX
- multi-phone sync
- product polish unrelated to detector behavior

We do **not** have the original source code or binaries. Everything here is inferred from:

- direct physical testing
- app screenshots / captures
- the academic paper in this folder
- computer vision research

## Source Of Truth Files

- [PHOTOFINISH_RAW_TESTS.md](/Users/sondre/Documents/testingdetection/PHOTOFINISH_RAW_TESTS.md)
  - raw observations only
  - may include provisional tests, but should stay factual

- [photo_finish_spec.md](/Users/sondre/Documents/testingdetection/photo_finish_spec.md)
  - build-facing working spec
  - should distinguish `confirmed`, `high-confidence inference`, and `unknown`

- [photo_finish_inferences.md](/Users/sondre/Documents/testingdetection/photo_finish_inferences.md)
  - evidence -> inference -> confidence ledger
  - use this to justify spec changes

- [AssessingTheAccuracyOfThePhotoFinishTimingApp.pdf](/Users/sondre/Documents/testingdetection/AssessingTheAccuracyOfThePhotoFinishTimingApp.pdf)
  - supporting evidence only
  - paper is Android-focused, not automatic truth for iPhone

- `research_*.md`
  - CV and iPhone/Swift implementation notes

## Current Leading Detector Model

Current best model:

1. extract motion from video frames
2. form connected moving blobs/components
3. prefilter by global size
4. require motion at the center gate line or a very narrow gate band
5. choose the first **locally substantial connected slice** from the leading side
6. interpolate crossing time between frames

Important current interpretation:

- **pure geometry is the leading theory**
- torso-like behavior is currently treated as an **emergent result** of geometry, not as proof of a semantic torso detector
- the detector seems to reject thin leading tips and wait for a slice with better **continuous vertical support**

This model is supported by:

- thumb vs palm
- book corner vs flat edge
- bottle nozzle / diagonal orientation vs taller/blunter front slice
- lean-angle drift on the torso

## Documentation Rules

When new evidence appears:

1. update the raw log in `PHOTOFINISH_RAW_TESTS.md`
2. update the working rule in `photo_finish_spec.md`
3. update the evidence/confidence reasoning in `photo_finish_inferences.md`

Do **not** mix these layers.

- raw file = what happened
- spec = what we currently think the detector does
- inferences = why we think that, and how confident we are

If a result is not clean yet, mark it as **provisional** instead of forcing certainty.

## Current High-Value Unknowns

These are still worth resolving:

- exact local leading-slice rule
- gate width: one column vs narrow band
- exact limb rejection boundary under pure geometry
- exact internal motion representation: plain frame diff vs short accumulation / morphology / similar
- background subtraction: unresolved
- exact speed window boundaries

## Implementation Guidance

If building a prototype from this folder, start conservative:

- rear wide camera only
- stable frame rate
- `AVCaptureVideoDataOutput`
- luma-plane processing
- simple frame differencing first
- connected components
- global width/height prefilters
- local leading-slice selection based mainly on continuous vertical support

Do **not** start with:

- body-pose estimation
- explicit torso/body-part classifier
- heavy background subtraction
- complicated heuristics unsupported by tests

## Research Notes

Use these before inventing detector behavior:

- [research_01_frame_differencing.md](/Users/sondre/Documents/testingdetection/research_01_frame_differencing.md)
- [research_02_background_subtraction.md](/Users/sondre/Documents/testingdetection/research_02_background_subtraction.md)
- [research_03_blob_geometry_and_selection.md](/Users/sondre/Documents/testingdetection/research_03_blob_geometry_and_selection.md)
- [research_04_ios_swift_camera_pipeline.md](/Users/sondre/Documents/testingdetection/research_04_ios_swift_camera_pipeline.md)
- [research_05_clone_implications.md](/Users/sondre/Documents/testingdetection/research_05_clone_implications.md)

## Working Principle

Prefer a precise unknown over a false certainty.
