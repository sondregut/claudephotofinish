# Research 01: Frame Differencing and Temporal Motion Cues

This note summarizes the motion-detection literature that matters most for a Photo Finish clone.

## What Frame Differencing Actually Gives You

Frame differencing does not directly give you "the object." It gives you changed pixels between frames.

For a simple two-frame difference:

- leading-edge pixels appear where the object is now but was not before
- trailing-edge pixels appear where the object used to be but is no longer
- the interior of a slowly moving object may barely change at all

That matters because the detector may be making decisions from a sparse motion mask, not from a filled silhouette.

## Why Speed Changes What the Detector Sees

Two-frame differencing naturally creates three speed regimes:

- `too slow`: motion between frames is too small to survive thresholding, so detection can fail
- `usable middle`: enough displacement exists to create a stable motion mask
- `extremely fast`: the object can move so far between frames that the gate region is poorly sampled or missed altogether

That matches your current observations unusually well:

- slow hand swipe misses
- ordinary fast swipe can work
- super-fast swipe becomes invisible

This is a strong reason to treat "speed" as part of the detector's observable behavior, not just a tuning detail.

## Two-Frame vs Three-Frame / Multi-Frame Difference

Two-frame difference is the simplest model and the best first reproduction target.

More temporal support changes the mask:

- three-frame differencing can suppress one-frame noise and flicker
- accumulation over multiple frames can thicken motion masks
- any temporal accumulation can make a fast-moving object look larger than a single-frame debug box suggests

That matters because your current spec has one unresolved contradiction:

- a fast hand swipe triggered even though the visible debug box height looked too small

One explanation is that the detector's internal motion representation may be richer than the debug overlay.

## Thresholding Is Where "Motion" Becomes a Binary Mask

In practical systems, frame differences are almost always thresholded.

The threshold step matters because:

- low thresholds preserve faint motion but increase noise
- high thresholds drop faint edges and slow motion
- adaptive thresholding helps with uneven illumination, but changes geometry

For a timing clone, the conservative first build is:

- use the luma plane only
- compute absolute difference against the previous frame
- apply a fixed threshold first
- only move to adaptive thresholding if lighting tests force it

## What This Means for the Clone

Current best starting point:

1. Process the rear-camera luma plane.
2. Compute `abs(current - previous)`.
3. Threshold to a binary motion mask.
4. Run simple cleanup and connected-component analysis.
5. Apply a gate test and local point-selection rule.

What to watch out for:

- if you process too slowly, you will create artificial dropped-frame behavior that changes the detector
- if you use accumulation too early, you may accidentally make the clone trigger on cases Photo Finish misses
- if you ignore the super-fast "invisible" case, your clone will likely over-detect on swipes that Photo Finish misses

## Why This Research Matters to the Photo Finish Evidence

This literature explains several current observations without requiring semantic body understanding:

- thumb tip rejected, palm wins
- book corner rejected, book edge wins
- bottle nozzle rejected, broader body wins
- extreme lean drifts inward
- super-fast swipes become invisible

Those can all arise from a sparse motion mask followed by local geometric selection.

## Sources

- Weiming Hu, Tieniu Tan, Liang Wang, Steve Maybank, "A Survey on Visual Surveillance of Object Motion and Behaviors": [PDF mirror](https://www.cs.cmu.edu/~dgovinda/pdf/recog/01310448.pdf)
- OpenCV thresholding tutorial: [docs](https://docs.opencv.org/4.x/d7/d4d/tutorial_py_thresholding.html)
- Local paper for Photo Finish timing behavior: [AssessingTheAccuracyOfThePhotoFinishTimingApp.pdf](/Users/sondre/Documents/testingdetection/AssessingTheAccuracyOfThePhotoFinishTimingApp.pdf)
