# Research 05: Direct Implications for the Photo Finish Clone

This file converts the CV research and the current test evidence into concrete design pressure for the clone.

## Most Plausible Detector Family Right Now

The strongest current model is:

1. sample video frames at a stable frame rate
2. derive a motion mask from frame differencing
3. threshold and lightly clean the mask
4. label connected components
5. prefilter by full-component size
6. require motion at the gate line or a very narrow gate band
7. choose the first locally substantial connected slice from the leading side
8. interpolate crossing time between frames

That is the best fit across:

- torso tests
- elbow failures
- thumb rejection
- book-corner delay
- bottle-orientation behavior
- super-fast invisibility

## What Looks Less Likely

These are currently lower-probability explanations:

- full human pose estimation
- skeleton/body-part landmarks
- a fixed anatomical chest point
- optical-flow-heavy tracking as the main detector

They are not impossible, but the object-only tests make them much less attractive as the first clone target.

## The Core Split to Preserve in the Clone

The clone should preserve the difference between:

### Global qualification

Questions like:

- is the component tall enough?
- is it wide enough?
- is it moving at all?

### Local selection

Questions like:

- which exact point in this component should count as the crossing?
- does the leading tip count, or should we wait for a more substantial slice?

This split now explains a large fraction of the observed behavior without adding body-specific hacks too early.

## Recommended Default Choices for a Swift Prototype

Start with these defaults:

- rear wide camera only
- stable 30 fps target if the device can hold it cleanly
- `AVCaptureVideoDataOutput`
- `alwaysDiscardsLateVideoFrames = true`
- luma-plane processing only
- two-frame absolute difference first
- simple binary threshold first
- 8-connected components
- global component width/height prefilter
- gate test at center line or a 3-5 px band
- local score driven mainly by continuous vertical support

## What To Delay Until Evidence Forces It

Do not add these in v1 unless controlled tests force them:

- background subtraction
- heavy temporal accumulation
- semantic torso/body-part classification
- complicated adaptive thresholds
- large morphology kernels

Each of those can make the clone behave more like a generic surveillance detector and less like Photo Finish.

## Open Decisions That Still Matter

### Gate geometry

- one exact column
- or a narrow band

### Local score shape

- hard threshold
- or graded score

Current bottle results favor a graded score.

### Background modeling

- none
- lightweight adaptive baseline
- sample-based background model

Current evidence still leaves this open.

## Best Next Experiments

- bottle orientation ladder with 5-7 repeated angles
- book edge-to-corner sweep
- sharp tip versus blunted tip on the same rigid object
- attached versus detached protrusion
- gate-width offset test
- controlled board-removal background test

## Bottom Line

The research makes the current clone direction much clearer:

- treat Photo Finish as a geometry-and-timing detector, not a semantic body detector
- make local leading-slice support the center of the point-selection rule
- keep the capture pipeline stable enough that frame drops and auto camera features do not fake the detector's behavior

## Sources

- [research_01_frame_differencing.md](/Users/sondre/Documents/testingdetection/research_01_frame_differencing.md)
- [research_02_background_subtraction.md](/Users/sondre/Documents/testingdetection/research_02_background_subtraction.md)
- [research_03_blob_geometry_and_selection.md](/Users/sondre/Documents/testingdetection/research_03_blob_geometry_and_selection.md)
- [research_04_ios_swift_camera_pipeline.md](/Users/sondre/Documents/testingdetection/research_04_ios_swift_camera_pipeline.md)
- [PHOTOFINISH_RAW_TESTS.md](/Users/sondre/Documents/testingdetection/PHOTOFINISH_RAW_TESTS.md)
- [photo_finish_spec.md](/Users/sondre/Documents/testingdetection/photo_finish_spec.md)
