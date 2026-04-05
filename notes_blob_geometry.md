# Research 03: Blob Geometry, Connected Components, and Local Point Selection

This is the most directly useful research note for the Photo Finish clone.

## The Standard Geometry Pipeline

Once you have a binary motion mask, the usual next steps are:

1. optional morphology to remove specks or fill small holes
2. connected-component labeling
3. bounding-box/stat extraction
4. local selection at the gate

OpenCV exposes the standard pieces directly:

- thresholding turns differences into a binary mask
- opening removes small bright objects
- closing fills small dark holes
- connected components provide `left`, `top`, `width`, `height`, and `area`

## Why Connected Components Matter

Connected-component labeling is the cleanest explanation for your current global size results.

OpenCV's connected-components API works on a boolean image and supports both 4-way and 8-way connectivity. The stats include:

- leftmost x
- topmost y
- width
- height
- area

That maps almost perfectly onto the way your spec currently reasons about:

- full-component height threshold
- full-component width threshold
- single connected blob versus two separated sub-blobs

## 4-Way vs 8-Way Connectivity

This is not a trivial implementation detail.

With 8-way connectivity, diagonal neighbors count as one component.

That matters because your current clone hypothesis already assumes diagonal continuity may be enough for a thin leading tip to remain attached to a larger trailing body. OpenCV's default connected-components convenience overload uses 8-way connectivity, which fits that hypothesis well.

## Morphology and Why It Can Change the Chosen Point

Morphology is a likely source of "blob inflation" if Photo Finish does any cleanup internally.

- opening removes tiny isolated blobs and very thin protrusions
- closing fills small holes and can thicken a shape locally
- a small structuring element can change whether a leading tip survives long enough to be considered at the gate

This matters because your detector behavior is very sensitive to small leading protrusions:

- thumb vs palm
- book corner vs flat edge
- bottle nozzle vs broader body

Even a light morphology pass can shift those boundaries.

## The Most Important Clone Insight: Global Qualification vs Local Selection

Your object tests now strongly support a two-stage geometry pipeline:

### Stage 1: global qualification

The connected component must be large enough overall.

This explains:

- full-frame height threshold behavior
- width threshold behavior
- why a steep lean can still trigger even when the gate slice is tiny

### Stage 2: local selection at the gate

After the component is allowed, the app still has to decide where inside that component to trigger.

Current best model:

- scan from the leading side toward the interior
- skip thin or weakly supported slices
- accept the first slice with enough continuous vertical support

This single idea explains a large fraction of the current evidence.

## Why "Continuous Vertical Support" Fits Better Than "Absolute First Pixel"

The following tests all point in the same direction:

- thumb-leading hand swipe: thumb rejected, palm wins
- same book: corner-first waits deeper, flat edge does not
- same bottle: slivery/diagonal leading slice waits deeper, taller/blunter front slice detects earlier
- strong forward lean: chosen torso point drifts inward

These are all the same geometry problem in different costumes:

- a sharp leading tip
- followed by a broader, taller connected region

The detector appears to like the broader/taller region.

## What the Local Measurement Might Actually Be

Several local metrics could produce the observed behavior:

- vertical run length in the exact gate column
- summed occupied pixels in a narrow vertical band around the gate
- minimum run length across 2-5 adjacent columns
- a weighted score mixing run length, local area, and temporal persistence

The current evidence does not yet separate these.

What it does strongly suggest is that the detector is not simply asking:

- "did any point cross?"

It is asking something closer to:

- "what is the first connected slice that looks substantial enough to count?"

## Practical Prototype Recommendation

For a Swift prototype, the safest first geometry stack is:

1. thresholded motion mask
2. very light morphology only if noise forces it
3. connected components with 8-connectivity
4. full-component width/height prefilter
5. gate-band check
6. leading-slice score based primarily on continuous vertical support

This is a better first approximation than trying to hard-code torso-specific rules.

## Sources

- OpenCV connected components and stats: [docs](https://docs.opencv.org/3.4/d3/dc0/group__imgproc__shape.html)
- OpenCV morphology tutorial: [docs](https://docs.opencv.org/3.4/d3/dbe/tutorial_opening_closing_hats.html)
- OpenCV thresholding tutorial: [docs](https://docs.opencv.org/4.x/d7/d4d/tutorial_py_thresholding.html)
- Current project evidence: [PHOTOFINISH_RAW_TESTS.md](/Users/sondre/Documents/testingdetection/PHOTOFINISH_RAW_TESTS.md), [photo_finish_spec.md](/Users/sondre/Documents/testingdetection/photo_finish_spec.md)
