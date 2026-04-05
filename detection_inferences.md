# Photo Finish Inferences Ledger

This file is the bridge between raw evidence and the working spec.

- Raw observations belong in [PHOTOFINISH_RAW_TESTS.md](/Users/sondre/Documents/testingdetection/PHOTOFINISH_RAW_TESTS.md)
- Build-facing rules belong in [photo_finish_spec.md](/Users/sondre/Documents/testingdetection/photo_finish_spec.md)
- This file records the current inference, why we believe it, how confident we are, and what could still falsify it

## Confidence Scale

- `High`: repeated tests or multiple independent test families point to the same rule
- `Medium`: current evidence is strong, but one or two alternative explanations still fit
- `Low`: plausible working guess only

## Current Inferences

### 1. Global qualification and local point selection are separate stages

- Confidence: `High`
- Inference: the app first decides whether a connected moving blob is large enough overall to count, and only then decides which exact point inside that blob should be treated as the crossing point.
- Evidence:
  - Full-body/whole-object size thresholds behave like full-frame component checks, not gate-only checks.
  - A steep forward lean can trigger even when only a tiny torso sliver is at the gate, as long as that sliver is connected to a much taller body component.
  - The same book or bottle can qualify globally while still having its extreme leading tip rejected locally.
- Main alternatives:
  - A single-stage gate-only detector that somehow reconstructs full size from local information.
- What would weaken this:
  - A test showing that a globally too-small component can still trigger purely because a local gate slice looks substantial.

### 2. The local selection rule depends strongly on continuous vertical support

- Confidence: `High`
- Inference: the chosen crossing point is not the absolute first pixel or sharp tip. The detector appears to scan from the leading side and accept the first connected slice with enough continuous vertical support.
- Evidence:
  - Thumb-leading hand swipe: thumb rejected, broader palm selected.
  - Book test: flat edge selected near the true front; corner-first selected farther back.
  - Soap-bottle test: narrow top/nozzle selected farther back; rotating the bottle so the front slice becomes vertically taller moves detection forward.
  - Bottle transition looked smooth, not abrupt.
  - Forward-lean ladder on the torso shows the same pattern: stronger lean leads to farther-back placement.
- Main alternatives:
  - The detector is mainly reacting to blur or timing lag rather than local geometry.
  - The detector uses a generic local area score, with vertical support only acting as a proxy.
- What would weaken this:
  - A controlled object test where the local vertical support changes substantially but the chosen point does not move.

### 3. The app is not using semantic human pose estimation

- Confidence: `High`
- Inference: Photo Finish is using generic motion/blob geometry, not skeleton tracking or human-part segmentation.
- Evidence:
  - Towels, boards, laptop-like objects, and hand swipes can trigger.
  - White-on-white towel tests still work, which argues against a semantic detector tuned only to people.
  - Object-only tests obey the same local-tip rejection logic as torso tests.
- Main alternatives:
  - A hybrid pipeline where generic motion detection runs first and a lightweight torso heuristic runs second.
- What would weaken this:
  - Consistent evidence that only human-like shapes can ever survive the final local-point selection stage.

### 4. Torso-like behavior is mostly an emergent result of the same local geometry rule

- Confidence: `High`
- Inference: on runners, the app usually lands on the torso not because it explicitly knows "this is a torso," but because torso surfaces often provide the first locally substantial connected slice behind the runner's leading tips.
- Evidence:
  - Shoulder and stomach can both win when they are the most forward torso surface.
  - Head/neck are usually ignored, which fits them being thin leading protrusions.
  - The same shape rule shows up on thumb, book-corner, and bottle tests.
- Main alternatives:
  - There is a weak additional torso-favoring heuristic layered on top of the geometry rule.
- What would weaken this:
  - A test where a non-torso object has the same local geometry as the torso but is still consistently rejected while the torso behind it wins.

### 5. Body-part suppression is real, but it is not absolute

- Confidence: `Medium-High`
- Inference: the app often suppresses a smaller leading body part when a larger moving body follows behind it, but the leading explanation is still the same local geometry rule plus connectedness rather than a separate torso-aware module.
- Evidence:
  - Many arm/head cases are rejected while the torso behind them wins.
  - Repeated elbow/forearm-leading tests can still fail and detect the elbow/forearm blob instead.
  - Hand-on-hip and towel-leading tests suggest not every attached/small leading shape wins.
- Main alternatives:
  - All suppression is emergent from local geometry plus connectedness, with no extra torso bias at all.
  - There is a weak torso-favoring rejection rule that only appears in some poses.
- What would weaken this:
  - A clean object-only matrix showing body-specific favoritism even after geometry and connectedness are matched.

### 6. Super-fast misses are probably frame-sampling misses, not a hard speed cap

- Confidence: `Medium-High`
- Inference: extremely fast swipes are becoming invisible because they cross the gate between sampled frames, not because the app contains a hard-coded "too fast" rejection threshold.
- Evidence:
  - Ordinary fast passes still work.
  - Only the extreme end becomes completely invisible, with no debug box.
  - This matches what a 30 fps gate detector would do if the object effectively teleported across the gate between frames.
- Main alternatives:
  - A hidden blur-based or temporal-consistency rule that penalizes very fast motion.
- What would weaken this:
  - A controlled high-speed test showing visible motion at the gate but a consistent algorithmic rejection anyway.

### 7. Background subtraction remains unresolved

- Confidence: `Low-Medium`
- Inference: frame differencing is almost certainly present; an additional background model may or may not exist.
- Evidence:
  - Standing still for a long time then sprinting still triggers.
  - Some box-removal tests looked like the object had been absorbed into background and removal no longer counted.
  - The box-removal result has not been cleanly repeated under strong controls.
- Main alternatives:
  - Pure frame differencing with no background model.
  - Frame differencing plus a lightweight running background or adaptive baseline.
- What would weaken this:
  - Repeatable board-removal tests that clearly behave one way or the other under controlled waiting times.

### 8. The detector may be sensitive to arrival into the gate, not just resumed motion while already overlapping it

- Confidence: `Medium-High`
- Inference: a qualifying slice may need to newly enter the gate region to trigger cleanly. Simply holding an object already on the line and then resuming motion may not be equivalent.
- Evidence:
  - Repeated test: starting a clearly-large-enough object just before the gate, pausing, then pushing it through fired.
  - Repeated test: starting the same clearly-large-enough object already overlapping the gate, pausing even only briefly, then pushing it farther through or away did not fire.
  - Repeated test: starting the same clearly-large-enough straight-edge object on the line, moving it slightly back off, then pushing it through again fired.
- Main alternatives:
  - The result is mainly a narrow-band effect.
  - The result is caused by leading-edge versus trailing-edge asymmetry in frame differencing.
  - The chosen qualifying slice may already have effectively crossed before motion resumed.
- What would weaken this:
  - Clean repeated trials showing that "already on the line, then move" triggers just as often once shape and alignment are tightly controlled.

## Current Best Detector Family

- Per-frame motion extraction from video frames
- Global connected-component prefilter for width/height
- Gate intersection test at the center line or a very narrow band
- Local point selection based on connected leading-slice support
- No explicit torso/body-part classifier in the default model
- Linear interpolation between frames for time
- Optional low-light correction using exposure duration

## Still Worth Testing Next

- Tight bottle ladder with 5-7 angles and repeated screenshots
- Book edge-to-corner sweep with the same distance/speed
- Attached versus detached protrusion on the same rigid object
- Gate-width offset test using a tall rigid object
- Controlled board-removal background test
