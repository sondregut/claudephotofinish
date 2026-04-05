# Photo Finish App — Reverse Engineering Specification

## Purpose

This document captures everything we know (confirmed through testing) and everything we still don't know about the Photo Finish sprint timing app. The goal is to replicate the app's detection and timing logic as accurately as possible.

**Project constraint:** This is a behavioral clone of a third-party App Store app. We do **not** have the original source code, APK/IPA binaries, or any decompiled artifacts. All conclusions in this spec must therefore come from direct observation, physical testing, app-paper statements, and high-confidence inference. Whenever the spec states something stronger than the evidence supports, it should be marked as inference rather than fact.

**Current scope (Phase 1):** We are working on the **detection algorithm only**. That means the current target is the logic that turns camera frames into a trigger point / chest-marker position / crossing time. UI, saved-image UX, status text presentation, multi-phone synchronization, start modes, and other product features are explicitly out of scope for the first build unless they directly affect the detector's internal behavior.

**Spec maintenance rule:** Some current claims in this document are still provisional and may require clarification. As new evidence comes in, the spec should be updated immediately to do one of three things: tighten a claim, downgrade it from "confirmed" to "inferred/open," or split platform-specific behavior apart. We should prefer a precise unresolved question over a false certainty.

---

## 1. App Overview

Photo Finish is a sprint timing app. The user mounts their phone on a tripod in portrait orientation at the edge of a track. A vertical red line (the "gate") is displayed at the center of the screen. When an athlete runs past and crosses the gate line, the app records a timestamp.

The app displays status messages: "Athlete too far", "Detection ready", or a timestamp after detection. There is a start button, but the app is ready to detect almost instantly after the phone stops moving — there is no lengthy calibration period.

**Platform note:**
- The direct behavioral testing documented in this project was performed on **iPhone**
- The clone target for implementation is also **iPhone**, using **Swift**
- The academic paper we have is specifically about **Photo Finish: Automatic Timing v3.3.1 on Android**
- Therefore, paper-derived technical details should be treated as **supporting evidence**, not automatic ground truth for iPhone
- For Phase 1, when paper claims conflict with direct iPhone observations, the **iPhone observations win**

---

## 2. Core Detection Algorithm

### 2.1 Frame Differencing (Partially Confirmed)

The app uses some form of frame differencing to detect motion. The exact method is unknown — it could be pure frame diff (N vs N-1), a multi-frame accumulation, or another technique entirely.

**What we know:**
- Objects that sit perfectly still are invisible to the app, regardless of how long they've been in the scene. The moment they move, they are detected. This is consistent with frame differencing — if nothing changes between frames, there is nothing to detect.
- A person who stood completely still in the camera's view for 30+ seconds was detected instantly on the first movement.
- A person who stood still for 30 seconds near the gate line and then sprinted through was detected. This means the app did not "forget" them or absorb them — it simply couldn't see them while they were still, and the moment they moved, the difference was large enough to trigger.

**What we don't know:**
- Whether the comparison is frame N to N-1 specifically, or some other differencing window. N-1 is the simplest approach and gives the smallest time gap (33ms at 30fps), but this has not been confirmed.
- The exact differencing method (pure frame diff, accumulated motion, optical flow, etc.).

### 2.2 Background Subtraction (Unresolved)

Whether the app also uses background subtraction (maintaining a stored reference image of the empty scene) is not fully confirmed.

**Evidence for background subtraction:**
- In one test, a large box was placed on the gate line, left perfectly still for a long time, then yanked away fast sideways across the gate. It did NOT trigger. If this were pure frame differencing, the removal should have triggered because there was a large frame-to-frame pixel change. The fact that it didn't suggests the box was "absorbed" into a background model, and its removal simply returned the scene to match the background — so no foreground object was detected.
- However, this test was inconsistent — sometimes it triggered, sometimes it didn't. The inconsistency may have been caused by variable pull speed, pull angle, or slight wobbling of the box keeping it "alive" in the frame differencing.

**Evidence against background subtraction:**
- A person who stood still for 30 seconds then sprinted through the gate DID trigger. If the background model absorbed them in that time, the sprint should not have triggered (or should have behaved differently). This is consistent with pure frame differencing.
- The app is ready to detect almost instantly after the phone stops moving, even in a completely new environment. This would mean the background model is built from just one or two frames, which is essentially the same as frame differencing.

**Current best guess:**
The app primarily uses frame differencing (N vs N-1). Whether there is an additional background subtraction layer remains unconfirmed. For replication purposes, start with frame differencing and add background subtraction later if needed.

### 2.3 What the App Likely Sees

**Note:** The exact internal representation is unknown. The following describes what a pure frame-diff (N vs N-1) approach would produce, which is one possible implementation.

If the app uses frame differencing, it does not see a solid filled silhouette of the runner. It would see:
- A strip of changed pixels at the **leading edge** (where the body is now but wasn't in the previous frame)
- A strip of changed pixels at the **trailing edge** (where the body was in the previous frame but isn't now)
- The **middle of the body** would show little to no change between frames because those pixels are occupied by the body in both frames

For a thick, slow-moving object (like a torso at jogging speed), the leading and trailing edges are close together and the middle area is large — meaning most of the body would be invisible to frame differencing. Only the edges show up.

For a fast-moving object, the leading and trailing edges are far apart, so more of the change is visible.

However, if the app uses a different technique (accumulated motion, background subtraction, etc.), the internal representation could be quite different.

### 2.4 From Changed Pixels to "Blob" Measurements

Later sections refer to the app measuring a "blob's" height and width and finding a detection point. The exact internal representation of the blob is unknown, but the measurements are confirmed:

- **Height measurement:** The topmost to bottommost changed pixels anywhere in the frame. This is the blob height. (Confirmed: height check is on the full-frame bounding box — see section 4.1.)
- **Width measurement:** The leftmost to rightmost changed pixels. This is the blob width.
- **Detection point at the gate column / narrow gate band:** The app appears to choose the first locally substantial connected slice from the leading side. Current object tests suggest this local rule depends heavily on continuous vertical support at the gate, not on the absolute first pixel or first sharp tip.

**Note:** Whether the app works with sparse edge strips (from pure frame diff), solid filled blobs (from background subtraction), or some other representation is unknown. The observable behavior (height/width thresholds, detection point logic) is the same regardless of the internal representation.

---

## 3. Detection at the Gate Line

### 3.1 Center Gate Region (Partially Confirmed, Exact Width Unresolved)

The app checks a very narrow region at the exact center of the screen where the red line is drawn. What is still unresolved is whether this region is:

- one exact pixel column
- a small multi-column vertical band centered on the red line

**Evidence:**
- A person sitting close to the camera, with their body covering the gate line, triggered detection just by shaking/moving their body — without crossing from one side to the other.
- The same person sitting close to the camera but NOT on the gate line did NOT trigger by shaking.
- Detection only fires when something is actually on the middle gate line.

**What this confirms:**
- The gate test is centered on the visible red line, not on arbitrary blob tracking elsewhere in the frame
- Motion must reach the center gate region to trigger
- A new provisional bottle test suggests there may be a difference between a qualifying slice **arriving into** the gate region versus an object simply resuming motion after already overlapping the gate line

**What this does NOT yet confirm:**
- Whether the gate region is exactly one column wide
- Whether the app internally expands the gate into a narrow band for robustness
- Whether "already on the line, then move" should be treated the same as "approach the line, then cross it"

### 3.2 Detection Logic (Confirmed)

The detection is NOT about an object "crossing" from one side of the gate to the other. It is about whether there is sufficient motion at the center gate region in the current frame comparison. The full pipeline is:

1. Compute frame difference (frame N minus frame N-1) across the entire frame
2. From the changed pixels, measure the bounding box (topmost to bottommost, leftmost to rightmost changed pixels — see section 2.4 for how this works with sparse edge strips)
3. Pre-filter: check bounding box width ≥ 8% of frame width → if not, discard
4. Pre-filter: check moving component height ≥ 30% of frame height → if not, discard
5. Check the center gate region: are there changed pixels at the gate?
6. Find the detection point at the gate (first locally substantial connected slice from the leading edge — see section 6)
7. **Body-part suppression check:** If the region at the gate is only a small part of a larger moving blob that has not yet fully arrived at the gate, detection is **deferred** — the app waits for the larger body (e.g., the torso) to reach the gate before triggering. This means passing all size and speed thresholds is necessary but NOT sufficient. See section 6.4 for full details.
8. If all checks pass → trigger detection

The size thresholds (height and width) are NOT simple "gate-column-only" checks. The strongest current interpretation is:

- The center gate region is where the app decides whether a crossing is happening
- The height/width thresholds are evaluated on the moving blob/component that reaches the gate
- The portion of the blob exactly on the gate does **not** itself need to be 30% of frame height
- A small forward tip at the gate can still trigger if it is connected diagonally or vertically to a larger moving blob that satisfies the size requirement

This is supported by 2026 test 6: a runner leaning forward steeply had only ~6% of frame height at the gate line itself, but still triggered because that forward chest region was connected to a much larger moving body blob in the frame.

**Start-position nuance from repeated object testing:**
- Using a clearly-large-enough object, starting just before the gate, pausing briefly, then pushing through fired repeatedly
- Using the same clearly-large-enough object already overlapping/on the gate line, pausing briefly or only very shortly, then pushing it farther through or away did **not** fire repeatedly
- Starting the same clearly-large-enough straight-edge object on the gate line, moving it slightly back off the line, then pushing it through again **did** fire repeatedly
- This now looks like a real behavioral boundary rather than a one-off bottle artifact
- The strongest current interpretation is that the detector cares about a qualifying leading slice **newly reaching** the gate region. Resetting that slice back off the line appears to restore detectability, while simply resuming motion from an already-overlapping position does not
- This is therefore unlikely to be a simple size-threshold artifact. More plausible explanations are: a narrow gate band, leading-edge versus trailing-edge asymmetry in the motion mask, or the chosen slice already having effectively "crossed" before motion resumed
- This still does **not** prove background subtraction by itself

### 3.3 Both Directions Detected (Confirmed)

The app detects motion crossing the gate in both directions — left to right and right to left. (Test 20: rapid back-and-forth crossing triggered both directions.)

---

## 4. Size Thresholds

### 4.1 Height Threshold (Confirmed Outcome, Geometry Inferred)

The moving region that reaches the gate must belong to a **single connected moving blob/component** that is at least approximately **30% of the total frame height**. The exact slice of changed pixels at the gate column does NOT itself need to be 30% tall.

**Evidence:**
- Objects ≥30% of frame height at walking speed or faster: triggered (tests S3, S23)
- Objects <30% of frame height: did not trigger (tests S4, S23)
- Two separated objects each below 30% but spanning >30% together: did NOT trigger (tests S12, S24). This means the app looks for a single continuous vertical span, not the total extent of all changed pixels.
- A person crouching to make their entire body shorter than ~25-30% of frame height: did not trigger (2026 test 7)
- A runner leaning forward steeply had only ~6% of frame height at the gate column, but still triggered because the forward chest region was connected to a much larger body blob that was well over 30% tall (2026 test 6).

**Current working interpretation for cloning:**
- The app likely works with connected motion components, not just isolated pixels on the gate column
- The height rule is best modeled as "the gate-touching motion must belong to a connected component whose vertical span is ≥30% of frame height"
- Diagonal connection likely counts, not just perfectly vertical continuity
- This interpretation resolves the contradiction between the observed lean-forward trigger and the earlier wording that implied a gate-column-only height check

**Important caveat from the fast hand-swipe test:**
- A fast hand/arm swipe triggered even though the debug overlay showed only 15.7% of frame height
- A slower hand/arm swipe at similar apparent size did NOT trigger
- For cloning, this should NOT yet be treated as proof that the 30% rule is wrong
- The better working interpretation is that fast motion may change the internal blob the app measures (for example via motion blur, multi-frame accumulation, or blob inflation), or the debug overlay may not reflect the exact internal thresholding geometry
- So the current spec keeps the 30% connected-component rule, but marks fast small-object triggers as an unresolved speed-coupled effect

### 4.2 Width Threshold (Confirmed, but mechanism unclear)

Objects must be at least approximately **8% of the frame width** to trigger detection.

**Evidence:**
- A thin broomstick (~4cm, <8% of frame width) was never detected at any speed (tests 42, S9, 2026 test 1)
- A thin pencil/stick was described as "Athlete too far too small" by the app (2026 test 3)

**How width works with a single gate column:** The width threshold is likely a separate pre-filter that runs on the full frame, not at the gate column. The app probably measures the overall width of the moving blob across the entire frame. If the blob is too narrow (less than 8% of frame width), it is discarded entirely before the gate column check even runs. This explains why thin objects like broomsticks and pencils never trigger — they are filtered out at this stage regardless of their height or speed.

### 4.3 Size Thresholds Are Frame-Relative (Confirmed)

The thresholds are percentages of the total frame dimensions, not absolute pixel counts. This means the same real-world object will meet the threshold when close to the camera (appearing larger) and fail when far away (appearing smaller).

---

## 5. Speed Thresholds

### 5.1 Minimum Speed (Confirmed, value unknown)

There is a minimum speed required for detection. Very slow movement does not trigger.

**Evidence:**
- Crossing the gate extremely slowly: no detection (test 12)
- Moving an object very slowly through the gate: no detection (tests S2, S5, S8)
- Approaching slowly then accelerating right at the gate line: triggered (tests 37B, S14)
- A static object placed on the gate line: no detection (tests S1, 2026 test 4)

The actual minimum speed value (in pixels per frame or real-world units) has not been measured. This is a tuning parameter for replication.

There is also likely an interaction between speed and apparent blob geometry. The fast hand-swipe result suggests that higher speed may make the app's effective motion blob larger or otherwise more detectable than the debug overlay implies. Because a slower swipe at similar apparent height did not trigger, speed is not just a secondary detail here — it may alter the blob the detector actually evaluates.

### 5.2 Effective Upper-Speed Failure (Observed, likely caused by 30fps sampling)

There appears to be an **effective upper-speed failure mode** where extremely fast objects do not trigger. This should **not** currently be interpreted as proof of an explicit coded "maximum speed threshold." A better working interpretation is that, at 30fps, some objects move so far between frames that the detector cannot reliably see usable motion at the gate.

**Evidence:**
- User testing indicates that insanely fast hand/arm swipes across essentially the whole frame can become completely invisible to the detector, with no usable motion/debug box seen, even when the moving object would normally be large enough and wide enough to qualify
- User clarification indicates that ordinary fast crossings are still detected; the miss only appears at the **super super fast** extreme
- This means the detector is not monotonic with speed: faster is not always more detectable

**Current best explanation:** At very high speeds, the object completely passes the gate region between two consecutive 30fps frames. In frame N-1 it's on one side, in frame N it's on the other side, and at the actual gate there may be no usable sampled motion at all. From the detector's point of view, the object effectively "teleported" past the gate.

For cloning, this should currently be modeled as a **frame-sampling limitation / gate-miss effect**, not as a proven hard speed cap in the algorithm.

### 5.3 Speed Is Likely Pixel-Based (Unconfirmed)

The speed threshold is probably measured in pixel displacement per frame rather than real-world speed. This has not been tested — one way to test would be to find the threshold speed at different distances from the camera and see if it changes in real-world terms.

---

## 6. Detection Point Logic

### 6.1 No Pose Estimation or Body Recognition (Confirmed by tests, but paper language differs)

The app does not use any form of human body detection, skeleton tracking, or pose estimation. It works on any object that meets the size and speed thresholds.

**Evidence:**
- A towel with no person present triggered detection (tests 5, 40)
- A laptop/board with no person triggered when close enough (test 41)
- A hand swipe across the lens triggered (test 22c)
- A white towel against a white wall triggered (test S25)

**Paper language to reconcile:** The paper repeatedly describes the system as a "chest detection algorithm" and says it is calibrated for running, even claiming it can detect a cyclist's chest instead of the front wheel. However, our direct tests show unmistakably that the app can also trigger on non-human objects. For cloning, the safest interpretation is:

- The app is NOT doing strict human-only pose estimation
- It likely uses motion/blob heuristics that were tuned so that, in typical running scenes, the chosen trigger point lands near the torso/chest
- The paper's "chest detection" wording may describe the intended output of those heuristics rather than a full semantic body-part recognition model

### 6.2 Detection Point Is Near the Leading Edge of the Torso (Confirmed Outcome, Exact Internal Rule Still Inferred)

When a person runs through the gate, the app does not detect at the head, neck, arms, or legs. It detects on the torso, and more specifically appears to choose the **frontmost torso surface** rather than a point deep inside the body.

**Evidence:**
- Leaning forward: detection at top of shoulder/chest, not at the head which crossed first (tests 25, 33, 36)
- Extended arm ahead of body: detection at chest, not the arm (tests 27, 28)
- Stomach leading (leaning backward): detection at stomach (tests 26, 29, 30)
- Shoulders forward, hips back: detection at shoulder (test 34)
- Hips forward, shoulders back: detection at stomach (test 35)
- iPhone observational clarification: when visually comparing the athlete to the gate line, the app consistently behaves as though it is choosing the **very tip of the torso contour**, excluding the neck/head and excluding arms/legs
- Additional iPhone screenshot evidence: in user-provided finish captures, the selected crossing appears to occur **more or less immediately** when the frontmost torso contour reaches the gate line, not after a substantial extra amount of torso thickness has passed the line
- Additional clarification from user review: in those example captures, the app appears to choose the **most forward part of the torso**, and if the stomach is the most forward torso region then the stomach is chosen. This matches the existing stomach-forward raw tests rather than adding a new contradiction.
- Additional clarification from user review: when crossing more sideways, the chosen point can be the **side of the stomach** or the **shoulder region**, again matching the most forward torso surface rather than a fixed anatomical "chest" point
- Additional clarification from user review: the **shoulder does count as torso** for detection purposes. If a few pixels of shoulder are the first torso pixels past the gate, that is still considered correct behavior rather than an error.
- Additional clarification from user review: shoulder-leading detections look good in practice, and from a side view the shoulder and torso contour are visually very similar. For cloning, this means we should not overfit a sharp shoulder-vs-torso distinction when the side silhouette is effectively one continuous torso shape.
- Additional clarification from user review: in a sideways crossing with the face toward the camera and a hand resting on the hip, Photo Finish appeared to reject the hand-on-hip region and still select the torso. This suggests that a small attached hand region does not automatically pull the chosen point forward just because it is part of the visible outer contour.
- Additional clarification from user review: when the neck is far forward in a lean, the app should be modeled as **ignoring neck/head** and then choosing the torso
- Additional clarification from user review: leg/foot-leading poses are hard to test, but when the lower leg is held **truly vertical** at the gate and the torso is not moving much, Photo Finish can detect the leg. When the leg is not fully vertical, it does not. This strongly supports a geometry/vertical-extent explanation rather than a special foot-specific rejection rule.
- Additional clarification from user review: the chosen point is **usually** visually correct at the front torso contour, but **rarely** appears slightly too far back inside the torso
- Additional clarification from user review: this rare slight backward placement seems to happen more often on **stronger forward leans**, while slightly less extreme forward leans more often land correctly on the front torso contour
- Additional clarification from user review: an informal lean ladder suggests a stronger trend, not just rare randomness: **small forward lean** is detected very accurately at the front torso edge, while **increasingly extreme forward lean** tends to move the chosen point progressively farther back inside the torso

**Current working interpretation for cloning:**
- The app appears to scan from the leading edge of the moving body backward
- The selected point is not just "torso somewhere"; it is the **frontmost qualifying torso surface**
- A small shoulder lead is acceptable because shoulder belongs to the torso class in the current behavioral model
- In side views, shoulder-versus-torso separation is probably not meaningful at pixel level; the detector can be considered correct if it lands on that shared leading torso contour
- Head/neck/arms/legs are avoided even when they are farther forward; neck/head in particular should currently be treated as explicitly excluded
- Leg/foot-leading outcomes currently appear to depend heavily on whether the pose creates a tall enough vertical blob; there is no good evidence yet for any special treatment of the lower part of the frame
- For forward leans, the trigger appears to happen nearly immediately once that frontmost qualifying torso contour reaches the gate
- Rare slight backward placements do occur, so the detector is not perfectly locked to the absolute outermost torso pixel on every frame
- Lean angle itself may be one of the factors that shifts the chosen point slightly inward on some runs
- Forward-lean severity now looks like one of the strongest known factors: the more extreme the lean, the more likely the chosen point shifts inward from the outer torso contour
- A small attached hand/arm contour does not always shift the chosen point forward, so the detector is likely applying a local thickness/shape criterion rather than blindly following the outermost merged silhouette
- Object-only tests now reinforce the same pattern: a thumb can be skipped in favor of the palm, a sharp book corner can be skipped in favor of the book face, and a bottle nozzle/diagonal tip can be skipped in favor of a broader/taller slice farther back
- With the same bottle held at different angles, the chosen point moved smoothly as the front slice became more or less vertically tall, which suggests a graded local-support score rather than a purely anatomical torso rule
- The exact internal criterion is still inferred; the best current model is "first locally substantial connected slice with enough continuous vertical support," which on a human runner usually lands on the frontmost torso surface

### 6.3 Local Qualification Depends on Continuous Vertical Support (High-Confidence Inference)

The local rule that decides the exact detection point appears to depend strongly on how much continuous vertical support exists in the frontmost slice of the connected moving blob. The detector is not simply taking the absolute first pixel or first sharp tip that crosses the line.

**Evidence:**
- In a hand swipe with the thumb clearly leading, the app appeared to reject the thumb tip and select the broader palm/hand region behind it (raw test 12e).
- With the same book at similar speed and distance, a flat leading edge was detected close to the true front edge, while a sharp corner-first crossing was detected farther back after more of the book had passed the gate (raw test 12f).
- With the same soap bottle, a narrow top/nozzle-leading orientation was detected farther back, while rotating the bottle so the front slice became vertically taller moved detection closer to the true leading edge (raw tests 12g, 12h).
- The bottle-orientation change looked smooth rather than abrupt, which argues for a graded local-support rule rather than a single anatomy-specific switch.
- A pillow strapped to the stomach (making the blob wider) did NOT change the detection point — the upper chest/shoulder still triggered when leaning forward.
- At both close and far distances from the camera, the same lean angle still triggered at the same body region.

**What this currently implies for cloning:**
- Global size qualification and local point selection are separate stages. A blob can be globally tall/wide enough to count, yet still have its extreme leading tip rejected locally.
- "Thick enough" should currently be modeled as local continuous vertical support in the gate column or narrow gate band, possibly combined with connectedness and short-term temporal stability.
- Widening a blob without improving the useful local leading support does not necessarily move the chosen point forward.
- The local rule is more likely object-relative than frame-absolute, but the exact normalization is still not proven.

**What we don't know:**
- The exact local measurement: single-column vertical run length, narrow-band area, multi-column continuity, or a combined score
- Whether the local threshold is normalized to the component's height, uses an absolute pixel run, or mixes both
- How much of the observed backward drift comes from geometry versus blur/frame-diff shape changes

### 6.4 Body-Part Suppression — Strong Pattern, But Not Perfect (Mostly Confirmed)

**Key rule:** In most tested cases, if a smaller body part (arm, elbow, hand, head) crosses the gate and meets all size and speed thresholds, but a larger moving body (e.g., a torso) is also present in the frame and approaching the gate behind it, the smaller part is **rejected**. Detection is deferred until the larger body arrives at the gate. Passing all thresholds is necessary but NOT sufficient — the app usually suppresses valid-looking detections when a bigger moving blob is following.

**Terminology clarification:** In the "elbow" tests, "elbow" means a pose where the forearm and hand are held roughly vertically in front of the body, creating a tall narrow vertical blob led by the elbow/forearm/hand assembly. It does not mean the elbow joint alone as an isolated point.

This is a critical rejection mechanism. Without it, every runner's leading arm or head would trigger a premature detection before the torso arrives. However, current evidence suggests this suppression is **not perfect** and can fail reproducibly in at least some elbow/forearm-leading poses.

**Evidence — suppression in action (smaller part rejected despite meeting thresholds):**
- Elbow pushed through gate while body was visible and moving: elbow rejected, detection fired later when torso arrived (test 8b)
- Arm in T-pose pushed through gate while body was moving: arm rejected, waited for torso (test 9)
- Arm ahead of body while body was moving: arm rejected, detected on body (test 11)
- Tall elbow through gate while torso was also moving: elbow rejected, waited for torso (test 12)
- Head/neck ahead of torso during a run: head rejected, detected at upper torso (tests 33, 14)
- Wide but vertically short object (~10-15px rows) passed through gate while a body was also present: short object rejected, detection fired later on the body (test 15). This shows suppression is not limb-specific — any small region is suppressed when a larger moving body is present.

**Known repeated failure case:**
- In later repeats of the elbow test, using elbows/forearms held in front of the body to create a tall narrow vertical blob ahead of the torso, Photo Finish repeatedly appeared to detect the elbow/forearm blob instead of waiting for the torso (raw test 12b). This means suppression should currently be treated as a strong tendency, not an absolute rule.

**Counterexample showing suppression can still work on attached hand/arm shapes:**
- In a sideways crossing with face toward the camera and one hand resting on the hip/torso silhouette, Photo Finish capture thumbnails appeared to reject the hand-on-hip region and still detect the torso (raw test 12c). This suggests the failure in 12b is not simply "any attached arm contour wins"; the exact pose/shape still matters.
- In a similar leading-object test using a small towel in front of the body, Photo Finish appeared to reject the towel and wait for the body instead of detecting the towel (raw test 12d). This further suggests the elbow failure in 12b is not explained by "any small leading object wins" and is likely sensitive to the specific pose/shape/motion geometry.

**When suppression does NOT apply (smaller part IS detected):**
- Body is completely off-screen — only the limb is visible: limb triggers (test 8a)
- Body is visible but perfectly still — only the limb is moving: limb triggers (test 8c, test 11 still case)
- No larger moving blob exists in the frame: the smaller part is the entire detection and triggers normally

**Mechanism (current best guess):** A **pure geometry / connectedness** explanation is now the leading model.

- The observed suppression can largely be explained by the same local leading-slice rule used everywhere else: the detector skips weakly supported leading tips and waits for the first connected slice that looks substantial enough to count
- On runners, that usually means the torso wins because it is the first large, vertically supported connected region behind the smaller tips of the head, arm, hand, or foot
- The repeated elbow/forearm-leading failure case now looks more like a geometry boundary case than proof of a separate torso-aware rejection module
- A separate torso-favoring bias is still possible in theory, but it is now a **lower-confidence fallback explanation**, not the primary one

For replication, the right starting point is therefore **pure geometry first**. An extra torso heuristic should only be added later if controlled tests prove that geometry and connectedness alone cannot reproduce the app.

**Why this matters for replication:** Any replica must implement this suppression. A naive pipeline that triggers as soon as *any* region at the gate meets height/width/speed thresholds will produce false-early detections on every runner's leading arm or head. The detection must be deferred until the "thick enough" part of the blob reaches the gate.

---

## 7. Timing / Interpolation

### 7.1 Linear Interpolation (Confirmed — from Paper and PDF)

The app uses linear interpolation between two frames to estimate the exact moment the detection point crossed the gate line.

- Frame N-1: the leading edge of the "thick enough" section is before the gate line
- Frame N: the leading edge has passed the gate line
- The app measures the distance from the leading edge to the gate line in both frames
- It interpolates linearly to estimate the precise crossing time between the two frame timestamps

The paper further states that the final time is calculated from:

- the frame timestamps
- the distance of the **chest marker** from the measurement line

This implies the app internally stores a marker position for the chosen trigger point, not just a boolean trigger event.

### 7.2 Camera Settings (Confirmed — from Paper)

- Frame rate: 30 fps on all phones
- All camera settings are automatic (exposure, ISO, focus, shutter speed)
- Shutter speed ranges from 0.5ms (bright outdoor) to 33ms (dim/indoor)
- Contrasting color between runner and background improves accuracy
- Camera timestamps correspond to the **beginning of exposure**
- Paper-tested app version: **Android v3.3.1**

### 7.3 Exposure-Duration Correction (Confirmed — from Paper)

The paper states that in lower light conditions, the algorithm tends to trigger between the middle and the end of a blurred image section. To compensate, Photo Finish adds:

- **0.75 × exposure_duration**

to the video frame timestamp.

This correction is described as an automatic timing optimization in low light. In bright daylight, the paper says exposure was around 1ms, making the correction negligible.

### 7.4 Saved Capture / Chest Marker Display (Android paper evidence; iPhone marker UI still unconfirmed)

The Android paper says Photo Finish saves and displays captured images with **white chest markers**, allowing the user to verify where detection landed.

On **iPhone**, we do **not** currently have direct confirmation of an explicit visible white dot/marker UI. A user-provided screenshot of three Photo Finish captures was initially interpreted as possibly showing an additional overlay, but the user clarified that the apparent white segment is just the **gate line** itself. Therefore, the screenshot supports torso-vs-gate alignment, but it does **not** yet confirm a separate marker visualization on iPhone.

For Phase 1, the important part is not the UI itself but the implication that the detector internally produces a marker position or equivalent crossing point after each trigger.

### 7.5 Reported Accuracy (from Paper)

- 75th percentile accuracy: 10ms
- 95th percentile accuracy: 14-15ms

---

## 8. Shake Detection

### 8.1 Mechanism (Confirmed)

The app uses the phone's **accelerometer/gyroscope** (not vision) to detect phone movement.

**Evidence:**
- The frame turns red even when the camera lens is completely covered (test 13). This means the shake detection is sensor-based, not vision-based.
- Slow phone movement does NOT trigger the red frame (test 14)
- After movement stops, the frame returns to normal after approximately 0.5-1 seconds (test 15)

### 8.2 Effect on Detection

When the frame is red (phone moving), detection is paused. No timestamps are recorded. Detection resumes once the phone is stable and the frame returns to normal.

---

## 9. Cooldown Between Detections

### 9.1 Minimum Gap (Confirmed)

There is approximately a **0.5 second** minimum gap between consecutive detections (test S7).

### 9.2 Mechanism (Confirmed)

The cooldown is **time-based** — a simple timer of approximately 0.5 seconds after each detection. The gate does NOT need to clear before a new detection can fire. The phone also needs to be still during this time (which it normally is since it's on a tripod).

**Untested scenarios:**
- What happens when two people cross simultaneously?
- What happens with two runners at very close intervals (less than 0.5s)?

---

## 10. Status Messages and Distance Logic

### 10.1 Status Messages (Confirmed)

- **"Athlete too far"** — shown when the detected person/object is too small in the frame (observed at ~10ft distance, test 1)
- **"Athlete too far too small"** — shown for very small objects like a pencil (2026 test 3)
- **"Detection ready"** — shown when the object is large enough in the frame (observed at ~5-7ft distance, tests 1, 11)

### 10.2 Likely Pixel-Size-Based (Unconfirmed)

The status messages are probably triggered by the pixel size of the detected motion, not actual measured distance. This has not been explicitly tested — a test would be: stand at 10ft (where "too far" normally shows) and hold a large board. If the status switches to "Detection ready," it's purely size-based.

---

## 11. Lighting and Environment

### 11.1 Lighting Robustness (Confirmed)

- Works in very dark conditions (test S18)
- Works in very bright conditions (test S18)
- Works after mid-session lighting changes — lights turned on/off (test S19)
- Flashlight pointed directly at camera does NOT cause false trigger (test S21)
- Low contrast (white clothes against white wall, white towel against white wall) still works (2026 test 5, test S25)

### 11.2 Background Robustness (Confirmed)

- People walking in the background (~10ft) do not trigger detection — they are too small (test 7)
- People standing still in the background do not interfere with detection of a runner (test 8)

---

## 12. App Configuration

### 12.1 Confirmed Settings

- **Orientation:** Portrait only (test 4)
- **Optimal distance:** 1.4-1.6m from track edge (from FAQ)
- **Frame rate:** 30fps (from paper)
- **Camera settings:** All automatic

---

## 13. Remaining Unknowns — Tests Needed

### 13.0 Highest-Impact Unknowns For Phase 1

If we started building the detector today, the biggest remaining uncertainties would be:

1. **Exact torso-point rule** — We know the app usually picks the frontmost torso surface, but we do not yet know the exact internal rule that decides when the point stays on the outer torso contour versus slipping slightly inward.
   - New object tests tighten this: the main unknown is now the exact **local leading-slice rule**, not whether the app is aiming for the torso at all.
2. **Limb rejection boundary** — Arms/elbows/hands/legs are often rejected, but not always. The leading model is now **pure geometry**, so the remaining unknown is the exact geometric boundary for when a limb-like blob is ignored versus incorrectly chosen.
3. **Gate geometry** — We still do not know whether the gate is one pixel column or a narrow band around the center line.
4. **Speed window** — We know there is a too-slow miss region and an extremely-too-fast miss region, but the usable middle range is not yet mapped.
5. **Internal motion representation** — We still do not know whether the app is using pure frame differencing, accumulated motion/blob inflation, or some additional background/modeling step that changes what the detector "sees."

### 13.1 Background Subtraction (Priority: Medium)

**What we don't know:** Whether the app uses background subtraction in addition to frame differencing.

**Conflicting evidence:** The box removal test suggested background subtraction (box absorbed, removal didn't trigger), but the stand-still-then-sprint test contradicts it (person sprinted after 30s of standing still and DID trigger).

**Recommended tests:**
- Repeat the stand-still-then-sprint test multiple times at different durations (10s, 20s, 30s, 60s, 120s) with proper controls (normal run before and after to confirm app is working)
- Use the "revert to background" test: leave scene empty 2 min → place board on gate 2 min → yank board away fast sideways. If doesn't trigger → background subtraction confirmed. Repeat multiple times for consistency.

### 13.2 Local Qualification Rule / Continuous Vertical Support (Priority: High)

**What we don't know:** The exact local geometric rule that makes a leading slice count as the detection point. Current object tests suggest the decisive variable is local continuous vertical support, not the absolute first pixel, and not simply the overall width of the blob.

**Best current evidence:**
- Thumb-leading hand swipe: thumb rejected, palm chosen (raw test 12e)
- Same book: flat edge chosen near the front, corner-first chosen farther back (raw test 12f)
- Same bottle: narrow nozzle/slivery front chosen farther back; rotating the bottle so the front slice becomes vertically taller moves detection forward (raw tests 12g, 12h)
- Forward-lean ladder: stronger lean behaves like the same problem on a torso, with the front slice becoming thinner and detection drifting inward

**Recommended tests:**
- Tight bottle orientation ladder: same bottle, same speed/distance, 5-7 orientations from tall/blunt front slice to slivery/diagonal front slice
- Book angle sweep: same book, same speed/distance, flat edge to corner-first
- Blunt-tip control: same book or bottle tip with a locally thickened leading tip (tape/paper) to see whether the chosen point moves forward
- Connected protrusion control: same rigid main object with a thin attached protrusion versus a slightly detached protrusion
- Forward-lean ladder: slight to extreme lean, explicitly recording how far inside the torso the point moves

### 13.2A Fast Small-Object Trigger / Blob Inflation (Priority: High)

**What we don't know:** Why a fast hand/arm swipe triggered when the debug overlay showed only 15.7% of frame height.

**Current working interpretation:**
- This does NOT yet falsify the 30% connected-component rule
- Fast motion may inflate the internal motion blob the app uses for thresholding
- Alternatively, the debug overlay may visualize a different box than the one used by the detector
- The fact that a slower swipe at similar apparent height did not trigger means speed is likely part of the explanation

**Recommended tests:**
- Repeat fast and slow hand/arm swipes at the same distance and record debug screenshots for both
- Test several speeds while keeping the same hand path and apparent size as constant as possible
- Test whether motion blur, not just geometric size, correlates with triggering
- Compare debug-box height to trigger outcome across many runs to see whether the debug overlay consistently underestimates the internal detection blob

### 13.2B Gate Region Width: Single Column vs Narrow Band (Priority: High)

**What we don't know:** Whether Photo Finish checks exactly one center pixel column or a narrow vertical band around the center line.

**What we do know:**
- Motion must reach the visible center line region to trigger
- Motion away from that center line region does not trigger
- Current evidence is strong enough to say the gate is centered on the red line, but not strong enough to claim one-column precision

**Recommended tests:**
- Use a very thin, high-contrast vertical object moved horizontally at consistent speed and distance, and repeat passes with sub-inch lateral offsets relative to the red line
- Record screen video while positioning the object so it just barely touches the visible red line versus just barely misses it
- Repeat the same pass from both left-to-right and right-to-left to see whether the effective gate width is symmetric
- If available, use an object thin enough that one extra pixel column of overlap would matter in the debug view
- Run the same test while the object is tall enough to satisfy the height rule, so only gate width is being isolated

**Interpretation goal:**
- If only exact overlap with the visual center line triggers, a one-column model becomes more plausible
- If near-miss passes still trigger within a small tolerance, a narrow-band model is more likely

### 13.2C Body-Part Suppression Mechanism: Mostly Emergent Geometry (Priority: High)

**What we don't know:** The exact geometric boundary where a leading limb/object is weak enough to be skipped versus strong enough to win. Current evidence now favors a mostly emergent geometry explanation over any special torso-aware rejection rule.

**Current working interpretation:**
- Pure geometry is the leading model
- Thickness/connectedness/local vertical support probably explain most or all of the behavior seen so far
- The repeated elbow/forearm-leading failure case suggests there are poses where the leading narrow blob crosses the local-support boundary and legitimately wins under the same geometric rule
- An additional torso bias is still possible, but it is now a lower-priority fallback explanation rather than the default

**Recommended tests:**
- Move a large rectangle behind a smaller leading object, and vary only the gap between them
- Keep the small leading object identical, but change whether the larger trailing body is moving or perfectly still
- Repeat with the trailing body visible but partly off-frame versus fully visible
- Compare a connected shape versus a disconnected shape that has the same apparent front contour
- Repeat the vertical elbow/forearm-leading pose multiple times at slightly different lean angles and arm positions to determine the boundary where the app starts selecting the elbow instead of the torso
- Test the same elbow/forearm-leading pose with the torso more square to the camera versus more sideways
- Test whether reducing the visible torso width/height makes elbow selection more likely
- Compare the elbow/forearm-leading pose against a small towel-leading pose at the same distance and speed to see whether rigidity, outline shape, or local width changes the outcome

**Interpretation goal:**
- If suppression disappears whenever the leading part is disconnected enough from the trailing body, or whenever the leading slice becomes locally strong enough, then geometry/connectedness is doing the work
- Only if clean object-only controls still show body-specific favoritism should we revive the torso-bias hypothesis

### 13.2D Backward Drift Inside the Torso Under Stronger Forward Lean (Priority: Medium)

**What we don't know:** Why the chosen point is usually at the frontmost torso contour for small/moderate lean, but drifts farther back inside the torso as the forward lean becomes more extreme.

**Current working interpretation:**
- The dominant behavior is still "frontmost qualifying torso surface"
- Increased forward-lean severity now looks like a primary factor rather than a minor coincidence
- New object-based results make a local-support explanation more likely: an extreme lean may create the torso equivalent of a book corner or bottle nozzle, where the frontmost slice becomes too slivery to win cleanly
- The backward drift may still also be affected by blur, frame differencing geometry, gate-region width, interpolation between frames, or the way the torso blob changes shape under extreme lean

**Recommended tests:**
- Compare bright-light versus dim-light runs with the same pose
- Compare slow, medium, and fast torso crossings with the same lean angle
- Capture repeated forward-lean finishes and explicitly map how the chosen point moves from slight lean to extreme lean
- Compare screenshot-selected positions against frame-by-frame screen recordings whenever the app looks slightly late/backward

### 13.2E Limb Rejection Boundaries: Arms, Elbows, Hands, Feet (Priority: High)

**What we don't know:** Exactly what makes a leading limb get rejected in most cases, yet occasionally win in specific elbow/forearm or lower-leg-vertical poses.

**What we want to map:**
- when a leading arm/hand/elbow is rejected and the torso wins
- when a leading arm/hand/elbow incorrectly wins
- when a lower leg/foot can win if it forms a tall enough vertical blob and the torso is not moving much

**Recommended tests:**
- Arm-forward sweep: compare hand, forearm, elbow/forearm vertical blob, and full arm extension at the same distance and speed
- Contact vs separation: compare arm pressed into torso, arm slightly detached, and arm clearly separated in front
- Foot-forward sweep: step through with toe pointed forward, foot dorsiflexed upward, knee-high marching pose, and exaggerated lunge pose
- Lower-leg vertical test: keep the shin truly vertical at the gate and compare torso moving a lot vs torso moving very little
- Same limb pose with torso moving a lot versus torso moving only slightly
- Same limb pose with torso more front-facing versus more sideways
- Same limb pose with body fully visible versus partly out of frame

**Interpretation goal:**
- Determine whether rejection is mainly driven by local width/thickness, by connectedness to the torso, by trailing-torso motion, or by a stronger body-part-specific bias. For legs/feet specifically, determine whether the key variable is simply whether the pose produces a tall enough vertical blob.

### 13.2F Torso-Tip Mapping Across Angles (Priority: High)

**What we don't know:** How the chosen torso point moves as body orientation changes across forward leans, sideways crossings, twists, and backward leans.

**What we want to map:**
- which exact torso surface wins at each body angle
- when the chosen point stays at the outer torso contour versus slipping slightly inward

**Recommended tests:**
- Forward-lean ladder: upright, slight lean, medium lean, extreme finish-line lean
- Backward-lean ladder: upright, slight backward lean, strong stomach-forward lean
- Sideways ladder: front-facing, quarter-turn, half-turn/sideways
- Twist ladder: shoulders-forward/hips-back and hips-forward/shoulders-back with repeat trials
- For each pose, record whether the chosen point looks like shoulder, upper chest, side of stomach, center stomach, or slightly inside the torso contour

**Interpretation goal:**
- Build a pose-to-detection map that tells us whether Photo Finish is following the true frontmost torso surface or a slightly more stable interior proxy under some angles

### 13.3 Width Threshold Mechanism (Priority: Low)

**Best guess:** The width threshold is a pre-filter on the full-frame blob, separate from the gate column check. This is consistent with all test results. Could verify by passing an object that is very tall (meets height threshold) but very narrow (below 8% width) through the gate at speed — if it doesn't trigger, the width pre-filter is confirmed.

### 13.4 Cooldown Details (Priority: Low)

**What we know:** Time-based, ~0.5s, gate doesn't need to clear.

**Untested scenarios:**
- Two people crossing at the exact same time — one detection or two?
- Two runners at intervals less than 0.5s — does the second get missed?

### 13.5 Speed Threshold Values (Priority: Low)

**What we don't know:** The actual minimum detection speed and the effective upper-speed failure boundary. Current evidence suggests the detector has a usable middle speed range: too slow fails, ordinary fast can work, and only the extreme high end fails. This is not critical for building the replica — it's a tuning parameter that can be adjusted empirically once the core detection pipeline is working.

**Recommended tests:**
- Use the same object and same path, then compare slow, moderate, fast, and extremely fast passes to find the detection window
- Repeat with an object that is clearly large enough in both height and width so speed is the only changing variable

### 13.6 Dropped Frame Handling (Priority: Low)

**What we don't know:** How the app handles dropped or delayed frames, which would affect interpolation accuracy.

### 13.7 Edge Cases (Priority: Low)

**Untested scenarios:**
- Two people crossing the gate simultaneously
- Wind blowing trees/flags in the background — false trigger rate
- Person partially cut off at top/bottom of frame
- Camera slightly tilted / not perfectly level

---

## 14. Recommended Implementation Order

### 14.1 Phase 1: Detector Only

Based on what we know, here is the suggested order for building the detector core first:

1. **Camera frame ingestion** — portrait video frames at 30fps-equivalent processing assumptions
2. **Frame differencing / motion extraction** — subtract frame N-1 from frame N, threshold the result
3. **Connected-component construction** — group changed pixels into motion blobs/components
4. **Component size filters** — apply the current best-guess width/height rules to the gate-touching moving component
5. **Gate intersection check** — require motion at the center gate column / narrow gate band
6. **Detection-point selection** — scan from the leading edge backward and choose the first "thick enough" section
7. **Body-part suppression behavior** — ensure smaller leading parts do not trigger early when a larger moving body follows
8. **Speed handling** — minimum speed threshold and fast-motion behavior / blob inflation effects
9. **Linear interpolation** — compute crossing time between adjacent frames using the chosen marker position
10. **Exposure correction** — add `0.75 * exposure_duration` when modeling low-light behavior

### 14.2 Later Phases: Non-Detector Features

These are intentionally deferred until the detector behavior is close to Photo Finish:

1. Shake detection / motion pause
2. Cooldown between detections
3. Status messages such as "Athlete too far" / "Detection ready"
4. Saved-image review UX and marker visualization
5. Multi-phone sync, start modes, audio/touch calibration, and other system features
