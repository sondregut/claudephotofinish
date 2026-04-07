# Pipeline Audit: Our App vs Photo Finish Spec

Generated 2026-04-06 from full codebase + spec review.

---

## 1. CAMERA SETTINGS (CameraManager.swift)

### 1.1 Session Preset
- **Current:** `.high` (1920x1080) → detection scale=6, downsamples every 6th pixel
- **Original committed:** `.hd1280x720` → scale=4, every 4th pixel
- **Spec:** 30fps, all auto settings
- **Problem:** Changed accidentally. At scale=6, thin motion edges (5px or less in source) disappear. At scale=4 they're visible. Directly explains worse detection.
- **Status:** [x] Fixed — reverted to `.hd1280x720`

### 1.2 Frame Rate
- **Current:** Locked to 30fps
- **Spec:** 30fps
- **Status:** [x] OK

### 1.3 Exposure
- **Current:** Full auto, no cap
- **Spec:** "All camera settings are automatic"
- **Status:** [x] OK

### 1.4 Video Stabilization
- **Current:** Not explicitly disabled
- **Problem:** Digital stabilization shifts pixels between frames. On a tripod this is unnecessary and can create false diffs or distort blob shapes. Also adds processing latency.
- **Fix applied:** `connection.preferredVideoStabilizationMode = .off` in both configureSession and switchCamera
- **Status:** [x] Fixed

### 1.5 Center Stage / Smart Framing
- **Current:** Not disabled
- **Problem:** On newer iPhones, Center Stage can crop/pan the frame, moving the effective gate position.
- **Fix applied:** Disable Center Stage defensively in `addCamera()` so it works on all iPhone models.
- **Status:** [x] Fixed

### 1.6 Video Rotation
- **Current:** Sets `videoRotationAngle = 90` but buffer still arrives landscape (`isLandscape=true` in all logs). Engine handles via transpose.
- **Status:** [ ] Harmless but redundant — needs review

---

## 2. DETECTION ENGINE — THRESHOLDS (DetectionEngine.swift)

### 2.1 diffThreshold = 15
- **Was:** 25 in original commit
- **Problem:** In low light with 33ms exposure, sensor noise can exceed 15, creating noise blobs that waste processing, merge with real blobs, or trigger body_part_suppression via spurious "larger blob."
- **Spec:** No exact value mentioned.
- **Status:** [ ] Needs review — may need to revert to 25 or make adaptive

### 2.2 heightFraction = 0.33
- **Spec:** "at least approximately 30%"
- **Current:** 33% → minH=105 pixels. At 30% it would be 96. The 9-pixel difference could matter.
- **Status:** [ ] Needs review

### 2.3 maxAspectRatio = 1.2
- **Logs show:** rejections at ratio=1.3
- **Spec:** Not mentioned. Added to reject hand swipes but may reject valid crossings.
- **Status:** [ ] Needs review

### 2.4 localSupportFraction = 0.25
- **Threshold:** `max(3, component_height * 0.25, frame_height * 0.08)`
- **For tall blob (80% frame = 256px):** requires 64 continuous vertical pixels at gate
- **Logs:** `run=56 need=57` (missed by 1), `run=39 need=59`
- **Status:** [ ] Needs review

### 2.5 minFillRatio = 0.25
- **Spec:** Not explicitly mentioned. Added for hand-swipe rejection.
- **Status:** [ ] Needs review

---

## 3. BODY PART SUPPRESSION (DetectionEngine.swift lines 280-296)

### Current logic
```
For each larger component not at the gate:
  if distance_to_gate <= 20% of frame width → suppress
```

### Problems
1. **No direction check** — Spec says suppress when larger body is "approaching." Current code suppresses if any larger blob is nearby, even if moving AWAY.
2. **20% approach zone = 36 pixels** — Too wide. Arm blob can easily be 36px from gate while torso IS the gate blob. Result: torso suppressed by arm.
3. **Any larger blob suppresses** — Noise blobs (especially with diffThreshold=15) can be larger than real detection and suppress it.
4. **Logs confirm missed detections:**
   - `gate_area=8874 approaching_area=12267 dist=17` — suppressed
   - `gate_area=5020 approaching_area=13125 dist=14` — suppressed
   - `gate_area=4617 approaching_area=9497 dist=10` — suppressed

- **Status:** [ ] Needs review — likely needs direction check and tighter zone

---

## 4. THUMBNAIL (DetectionEngine.swift)

### 4.1 Scale hardcoded to 4
- **Problem:** With `.high` (1080p), thumbnail only covers 67% of frame. Gate not centered.
- **Fix applied:** Both thumbnail functions now compute scale from actual buffer dimensions.
- **Status:** [x] Fixed

---

## 5. INTERPOLATION & TIMING

### 5.1 Position-based interpolation
- **Current:** Scans horizontal run at detectionY, measures dBefore/dAfter relative to gate
- **Spec:** "measures the distance from the leading edge to the gate line in both frames"
- **Current approach approximates this from diff mask (captures both old/new positions in one pass). Not identical but functionally similar.**
- **Status:** [ ] Needs review

### 5.2 Exposure correction
- **Current:** `if expSec > 0.002 { crossingTime += 0.75 * expSec }`
- **Spec:** "adds 0.75 × exposure_duration to the video frame timestamp"
- **2ms threshold not in spec but practically sound (bright light correction <1.5ms anyway).**
- **Status:** [ ] Needs review — minor

---

## 6. FRAME PROCESSING PIPELINE

### 6.1 Frame differencing
- N vs N-1, absolute difference, threshold → binary mask
- **Status:** [x] OK

### 6.2 Connected components
- 8-way connectivity, union-find
- **Status:** [x] OK

### 6.3 copyYUVPlanes every frame
- **Current:** Copies full Y + CbCr planes EVERY frame, even if no detection occurs
- **At 1080p:** ~3MB per frame × 30fps = 90MB/s of memory copies
- **At 720p:** ~1.4MB per frame × 30fps = 42MB/s
- **Needed for:** "use previous frame" thumbnail feature — after detection, we might want the frame before the current one
- **Possible optimization:** Only keep the previous frame's planes (already doing this), but could defer the copy until detection is likely (e.g., skip copy during cooldown period). Trade-off: if a detection happens right after cooldown, previous frame thumbnail won't be available.
- **Status:** [ ] Needs review — performance vs feature trade-off

### 6.4 Warmup
- 10 frames (~0.33s)
- **Status:** [x] OK

### 6.5 Cooldown
- 0.5s real-time based
- **Status:** [x] OK

---

## 7. TESTS NEEDED

### Test A: Baseline after fixes (covers 1.1, 1.4, 4.1)
**What:** Run 10-15 crossings in the same conditions as recent bad tests (low light, same distance/speed).
**Look for:** Detection hit rate, frame drops, thumbnail showing full frame with gate centered.
**Compare to:** The recent logs where crossings were missed and body_part_suppression fired.
**Confirms/denies:** Whether reverting to 720p + disabling stabilization fixes the core detection regression.

### Test B: Center Stage check (covers 1.5)
**What:** No code needed — just check your iPhone model.
- Center Stage on **front camera**: iPhone 12+
- Center Stage on **rear camera**: iPhone 15 Pro+ (uses ultrawide)
- If you're using the **back wide camera on iPhone 14 or earlier**, Center Stage doesn't apply and this is a non-issue.
**Confirms/denies:** Whether we even need to worry about this.

### Test C: Noise floor in low light (covers 2.1)
**What:** Add a temporary log inside the diff loop that counts total mask pixels per frame. Run with phone on tripod, nobody crossing, in low light.
```
[NOISE] frame=X mask_pixels=Y
```
**Look for:** If mask_pixels > 0 when nothing is moving → noise from diffThreshold=15. If consistently hundreds of pixels → too low, revert to 25.
**Also test:** Compare a few crossings at threshold=15 vs 25 in same lighting. Does 25 miss real crossings, or does it just filter noise?
**Confirms/denies:** Whether diffThreshold=15 is causing noise blobs in low light.

### Test D: Height threshold edge cases (covers 2.2)
**What:** No new code needed. After Test A, search the logs for any `[REJECT] height` where the blob height is between 96-105 (the gap between 30% and 33%).
**Look for:** Rejections like `height — 98/105` or `height — 100/105`. These would be blobs that pass at 30% but fail at 33%.
**Confirms/denies:** Whether 33% vs 30% is causing real missed crossings. If no rejections in that range → doesn't matter.

### Test E: Aspect ratio rejections (covers 2.3)
**What:** No new code needed. Search logs from Test A for `[REJECT] aspect_ratio`.
**Look for:** Were the rejected blobs real crossings or noise? Check timing — if an aspect_ratio rejection happens right before a valid detection of the same crossing, it was probably a real blob that got filtered.
**Confirms/denies:** Whether maxAspectRatio=1.2 is too strict. If no valid crossings rejected → keep it.

### Test F: Local support near-misses (covers 2.4)
**What:** No new code needed. Search logs from Test A for `[REJECT] local_support` where run is close to need (within 5).
**Look for:** `run=X need=Y` where X is close to Y. Were those real crossings?
**Confirms/denies:** Whether localSupportFraction=0.25 is too strict. If many near-misses on real crossings → lower to 0.20.

### Test G: Body part suppression (covers 3)
**What:** No new code needed. Search logs from Test A for `[REJECT] body_part_suppression`.
**Look for:** How many suppressions, and were they correct (actually suppressing an arm before torso) or wrong (suppressing the torso because an arm/noise blob was larger)?
**Confirms/denies:** Already confirmed as an issue from previous logs. This test determines severity after 720p revert. If still happening frequently → needs code fix (add direction check, tighten zone).

### Test H: Fill ratio rejections (covers 2.5)
**What:** No new code needed. Search logs from Test A for `[REJECT] fill_ratio`.
**Look for:** Were rejected blobs real crossings or sparse noise?
**Confirms/denies:** Whether minFillRatio=0.25 is rejecting valid crossings.

### Test I: Frame drop count (covers 6.3)
**What:** No new code needed. Search logs from Test A for `[FRAME_DROP]`.
**Look for:** How many drops per detection. At 720p this should be significantly fewer than the 18-34 drops seen at 1080p.
**Confirms/denies:** Whether 720p resolves the frame drop issue. If still dropping many → copyYUVPlanes optimization needed.

### Tests not needed right now
- **1.6 Video Rotation:** Harmless, engine handles it. Low priority.
- **5.1 Interpolation:** Would need high-speed camera to validate timing accuracy. Defer.
- **5.2 Exposure correction:** 2ms threshold is practically sound. Defer.

---

## 8. SUGGESTED TEST ORDER

1. **Test B first** (takes 10 seconds — just check your phone model)
2. **Test A** (the big one — run crossings, collect logs)
3. **Tests D, E, F, G, H, I** (all just log analysis from Test A — no extra running)
4. **Test C** (only if Test A still shows problems — needs a code change for noise logging)
