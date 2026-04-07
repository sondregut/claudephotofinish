# Detector Hypotheses & Failure-Mode Analysis

**Date:** 2026-04-06
**Build under analysis:** commit `307b689` + same-session instrumentation (DETECT_DIAG, GATE_DIAG, USER_MARK, [GAP], cyan interpolated gate line, yellow detector dot at `(gateColumn, detY)`).
**Purpose:** Deep code review against the Photo Finish spec + raw test history. Identify everything that *could* be biting us on real-body crossings, leg swipes, leans, slow swipes, and low light, before the next physical test.
**Constraint per user instruction:** **NO CODE CHANGES.** This file is documentation only.

This analysis walks the detector pipeline stage by stage, cross-checks each stage against the Photo Finish behavioral spec (`detection_spec.md`), the raw PF tests (`raw_test_results.md`), our own previous test runs (`test_runs_our_detector.md`), and flags every place where the implementation either (a) is known to misbehave, (b) deviates from the spec, or (c) has a plausible failure mode that the existing tests have not yet refuted.

> **Notation.** "PF" = Photo Finish app (the reverse-engineering target). "Our app" = `claudephotofinish`. Coordinates are in 180×320 process buffer space unless noted. `gateColumn = 90`, `gMin..gMax = 88..92` (5 columns).

---

## 0. TL;DR — what to suspect, in order

Ranked by how likely they are to bite the *next* real-body run:

1. **`detY` lands on the densest mask stripe, not the leading-edge body.** `analyzeGate` picks the column window with the highest **average longest vertical run**, then sets `detY = midpoint of that run`. On every test we have data for (A real bodies, B/C/E hand swipes), this lands too low — on the shin, the wrist, or the heel of the palm — because that subsegment of the mask happens to be the densest. Cross-references: Test A "early on lower leg" rate ~13/21, Test B all 8/8 USER_MARK Δy negative, Test C 4/5 negative incl. one disjoint-range artifact, Test D detY=192/200/213 on hands of height 120–136. Root cause is in `DetectionEngine.swift:789-882` (`analyzeGate`). **Most likely culprit for "early on leg" misses on real bodies.**
2. **Sliding-window averaging across disjoint Y-runs.** The 3-column window in `analyzeGate` averages each column's *longest* run, but does NOT verify the runs are vertically adjacent across columns. Test C produced a documented case where c88 ran 197..239, c89 ran 197..238, **c90 ran 262..305** (a full 23-pixel Y gap), and the window averaged the midpoints to land in a Y-zone where *no column had a pixel*. This is a distinct, geometrically-pure bug that real-body crossings will hit any time the leg and torso both have local maxima at the gate band.
3. **Leading-edge "scan" doesn't actually scan from the leading edge for a tip.** The code orders the *windows* leading-edge first and returns the first window that meets `need`, but inside each window it still picks "longest run anywhere in `comp.minY..comp.maxY`". So the leading-edge ordering only matters for tie-breaking between *X* positions, not for biasing *Y* toward the leading body part. Combined with #1, this is why head/neck never wins (good) but shin/wrist still does (bad).
4. **`localSupportFraction = 0.25` of blob height interacts with leg-leading poses pathologically.** For a full-frame runner (h≈258), `need = max(3, 64, 25) = 64`. A vertical shin with even 64 px of clean run alone clears it. Spec says PF rejects most leg/foot leads but accepts a *truly vertical* shin (test 15b). Our threshold gives the leg too easy a path because it keys on raw run length rather than position-within-blob.
5. **Body-part suppression (`DetectionEngine.swift:285-301`) is structurally weak.** No direction check, no "is the larger blob actually moving toward the gate" check, and the approach zone (36 px = 20% of W) is wider than the gate band itself. On real bodies the leg and torso are usually the **same** connected component, so suppression silently never fires for the failure mode it was supposed to fix. Test A confirmed this: the user observed leg-fires repeatedly, but no `body_part_suppression` rejects appeared in the log.
6. **Frame-differencing can't see the *interior* of slow-moving torsos** — by spec section 2.3, only leading and trailing edges show up. `diffThreshold=15` makes this worse on slow motion: Test C close-misses had `maxGap` of 80–120 px (vs 7–60 on Test B), meaning the slow-motion mask is so fragmented that "longest run" picks whichever subsegment survived. This couples directly with #1 and #2 — it's the substrate that makes them visible.
7. **`maxAspectRatio = 1.2` will reject real leans.** A runner leaning forward at finish-line angles (PF spec section 2.4 / 13.2D) compresses vertically and can produce blob aspect (W/H) above 1.2 for one or two frames. Test history doesn't have this yet because we haven't done real bodies, but it's a known limit of the rule and PF spec explicitly says width is only an *intake* prefilter.
8. **`minFillRatio = 0.25` mismatches what frame differencing produces.** A real torso through frame-diff is mostly *edges*, not a filled silhouette. Our hand-swipe tests showed fill ratios 0.32–0.39 — which is barely above 0.25 even for high-contrast hands. A slow runner against a low-contrast background could produce fill < 0.25 on one or two frames and lose those frames entirely. This creates a "miss the actual crossing frame, fire on the next one" timing artifact.
9. **`comp.area > best.comp.area` tie-breaker for the winning component.** When there are multiple gate-touching components, the largest one wins by area, not by leading-edge position. This is wrong for the "two runners" case but it can also be wrong for the "torso + foreground arm at the gate" case during a real run.
10. **Direction asymmetry from R>L scan ordering and front-camera mirror.** The `windowIndices` reversal flips scan order, but the mirror correction is only in the *thumbnail*. If a real-body run is mostly L→R, we're testing only one half of the detector. We don't yet know whether R→L behaves identically.

Everything below expands these and a few smaller items.

---

## 1. Pipeline as actually built

For the analysis to be unambiguous, here is the full pipeline as it currently runs, with file:line refs into `DetectionEngine.swift` (the engine itself) and `CameraManager.swift` (the capture wrapper).

```
CameraManager.captureOutput  (CameraManager.swift:409)
 ├─ frameCount += 1
 ├─ [GAP] log if wall-clock gap > 50 ms                       (CameraManager.swift:421-431)
 ├─ [CAM] log every 30 frames if exp/iso/cap changed         (CameraManager.swift:435-460)
 ├─ guard isDetecting && isPhoneStable                       (CameraManager.swift:462)
 ├─ [FRAME_DROP] log if dropped > 0                          (CameraManager.swift:464-468)
 ├─ copyYUVPlanes(currentFrame)  → currentPlaneCopy          (CameraManager.swift:476)
 ├─ engine.processFrame(...)                                  (CameraManager.swift:478)
 │    ├─ guard isActive
 │    ├─ frameIndex += 1
 │    ├─ lock pixelBuffer
 │    ├─ recompute scaleX/scaleY if buffer dim changed       (DetectionEngine.swift:159)
 │    ├─ extractGray() into bufferA or bufferB               (DetectionEngine.swift:171)
 │    ├─ defer { usingA.toggle(); hasPrevious = true }       (DetectionEngine.swift:179)
 │    ├─ guard hasPrevious                                    (DetectionEngine.swift:186)
 │    ├─ guard frameIndex > warmupFrames (10)                 (DetectionEngine.swift:189)
 │    ├─ cooldown check on REAL elapsed time (0.5 s)          (DetectionEngine.swift:194-197)
 │    ├─ frame diff into diffBuf, threshold into maskBuf      (DetectionEngine.swift:202-220)
 │    ├─ findComponents() (8-way union-find)                  (DetectionEngine.swift:223)
 │    ├─ for each component:                                  (DetectionEngine.swift:235-270)
 │    │    ├─ height ≥ minH (105 px)
 │    │    ├─ width  ≥ minW (14 px)
 │    │    ├─ fill ratio ≥ 0.25
 │    │    ├─ width ≤ 1.2 × height
 │    │    ├─ component must straddle gMin..gMax (88..92)
 │    │    ├─ analyzeGate() → GateAnalysis or nil
 │    │    ├─ if hasQualifyingSlice: pick best by area
 │    │    ├─ else: log "local_support" reject
 │    ├─ guard best != nil                                    (DetectionEngine.swift:272)
 │    ├─ log every size-qualified component as [COMP]         (DetectionEngine.swift:275-283)
 │    ├─ body-part suppression sweep                          (DetectionEngine.swift:285-301)
 │    ├─ position-based interpolation                         (DetectionEngine.swift:303-343)
 │    │    ├─ scan left  while maskBuf[detRow*W+x] != 0
 │    │    ├─ scan right while maskBuf[detRow*W+x] != 0
 │    │    ├─ direction = compCenter <= gateColumn ? L→R : R→L
 │    │    ├─ dBefore/dAfter from runLeftX/runRightX
 │    │    ├─ fraction = dBefore / (dBefore + dAfter)
 │    │    ├─ crossingTime = prevSec + fraction*dt - start
 │    ├─ exposure correction: if exp > 2 ms, +0.75*exp        (DetectionEngine.swift:346-349)
 │    ├─ [DETECT] log + DETECT_DIAG dump                      (DetectionEngine.swift:367-376)
 │    └─ return DetectionResult(...)                          (DetectionEngine.swift:378-394)
 ├─ pick chosen frame: usePrevious if fraction < 0.5          (CameraManager.swift:494)
 ├─ generate thumbnail off-queue                              (CameraManager.swift:501-510)
 └─ append LapRecord on main thread                           (CameraManager.swift:512-532)
```

Eighteen distinct stages, each of which can fail. The rest of this document goes through them one by one.

---

## 2. Stage-by-stage critique

### 2.1 Frame ingress + gap accounting (`CameraManager.swift:409-468`)

**What it does.** Every captured frame increments `frameCount`, logs `[GAP]` if wall-clock spacing > 50 ms (i.e. one frame skipped), logs `[CAM]` only when exp/iso/cap *changes* (1 Hz max), then enters the detection gate guarded by `isDetecting` and `isPhoneStable`. Dropped frames are counted by the `didDrop` callback and flushed as a single `[FRAME_DROP] N frames dropped since frame X` line on the next successful frame.

**Concerns / hypotheses.**

- **Cold-start `[FRAME_DROP] 16` after the first crossing is still firing in every recent test (B, C, D, E.1, E.2).** The `prewarmThumbnail` static call at startup is supposed to JIT-warm the vImage path, but per the recent logs the first crossing still drops ~16 frames. That's ~530 ms of lost capture *immediately after* a real detection, which can swallow the *next* runner's leading edge entirely if two crossings come within ~600 ms. This is logged in the audit as "deferred" but it's a real correctness risk on tight back-to-back crossings.
- **`isPhoneStable` is purely accelerometer-driven** (`CameraManager.swift:376-392`, threshold 0.15 m/s², 0.75 s settle timer). PF uses an accelerometer for shake detection too (spec 8.1), so this is fine in principle. But the 0.75 s settle timer means a tap on the phone body during a run will silently kill detection for 750 ms — without any log line saying so. That's three crossings on a fast race. **If our app suddenly "misses" a chunk of a session, check if `isPhoneStable=false` was firing in the background.**
- **The `[GAP]` log threshold is 50 ms, i.e. one whole frame skipped.** Our processing budget at 30 fps is 33.3 ms/frame. We have no warning when we're consuming 25–33 ms per frame and walking right up to the limit; a long-running session can drift into "almost dropping" territory invisibly. Not a correctness bug, but it makes performance regressions hard to spot.
- **`copyYUVPlanes` runs on every frame regardless of detection likelihood** (`CameraManager.swift:476`). At 720p that's ~1.4 MB/frame × 30 fps = 42 MB/s of memory-to-Data copies. This is the prime suspect for the Test A frame drops the audit document already flagged. *Possible bug:* the copy holds the pixel buffer's lock long enough that the engine's own `CVPixelBufferLockBaseAddress` might serialize against it on the same queue. They're sequential so this should be safe, but the *cumulative* time of (copy + extract + diff + components + analyzeGate + thumbnail prep) per frame is what determines whether we drop next frame.

### 2.2 Frame storage + `hasPrevious` toggle (`DetectionEngine.swift:171-186`)

**What it does.** Two ping-pong buffers `bufferA` / `bufferB` hold the last two grayscale frames. `usingA` flips after each frame. `previousTimestamp` is stored. `hasPrevious = true` after the first frame.

**Concerns.**

- **Camera switch correctly invalidates `hasPrevious`** when frame size changes (`DetectionEngine.swift:159-167`). Good — diffing across cameras would be catastrophic.
- **`hasPrevious` is NOT reset by the warmup-skip path.** During warmup (`frameIndex ≤ 10`), we still extract gray and toggle `usingA`, but we return nil before doing the diff. This means by frame 11 we have a valid `previous` *and* a valid `current` and the diff is real. Good.
- **`extractGray` does pointwise nearest-neighbor downsample with `scaleX = scaleY = 4`** (`DetectionEngine.swift:404-424`). This means we sample one pixel out of every 4×4 = 16, throwing 94% of the source. PF spec talks about the app working at full sensor resolution; we're working at ~1.6% of the source area. **This is fine in principle (frame differencing is robust to downsampling) but it does mean a thin vertical edge that's only 1–3 source pixels wide can land entirely between sample points and disappear.** The audit notes this was the original reason for reverting from `.high`/scale=6 → `.hd1280x720`/scale=4. We're at the floor now; going lower would worsen detection.
- **Nearest-neighbor downsampling, not box filter.** A box-filter (averaging the 4×4 source square) would be more noise-tolerant and would not lose thin edges. Nearest-neighbor is cheaper and matches what most fast detectors do, but it's worth knowing this is a tradeoff.

### 2.3 Warmup skip (`DetectionEngine.swift:189`)

**What it does.** First 10 frames after start are dropped to let auto-exposure settle (~333 ms).

**Concerns.**

- **10 frames may be too few for the front camera.** Test D logs show the front camera AE pinned at 4.17 ms for the entire session; that's a hint that AE convergence on front is more aggressive than back. But test logs don't indicate any false rejects in the first 10–20 frames, so leaving this alone is fine.
- **Warmup is not re-triggered after `isPhoneStable = false`.** If the user bumps the phone mid-session, AE may oscillate but no warmup window is granted. Not a current bug because we haven't seen mid-session false fires correlated with stability events, but it's a place to instrument if those start appearing.

### 2.4 Cooldown (`DetectionEngine.swift:194-197`)

**What it does.** 0.5 s minimum gap between detections, measured from real frame elapsed time (not interpolated crossing time). PF spec 9.1 says PF also has ~0.5 s cooldown.

**Concerns.**

- **The cooldown is enforced before the diff/components run, so a detection that *would* have fired during cooldown leaves no trace in the log.** When debugging "missing crossings" we have no record of what *almost* fired. Adding a `[REJECT] cooldown` log line (gated to once per cooldown window) would tell us whether bunched crossings are being filtered or were never detected.
- **`elapsed` is `now - start` where `start = sessionStart` is the timestamp of the first frame after `start()`.** This is correct, but worth flagging that any clock drift or frame timestamp anomaly will accumulate over a long session.

### 2.5 Frame differencing + threshold (`DetectionEngine.swift:202-220`)

**What it does.** Pixel-wise `|cur - prev| ≥ 15` → binary mask. Tight inner loop, unsafe pointers, no Accelerate/vDSP — pure scalar Int16 math over 180×320 = 57 600 pixels per frame.

**Concerns.**

- **`diffThreshold = 15` is the fundamental noise/signal control.** Lower → more sensitive but more noise. Higher → cleaner but loses slow motion. Test C documented `maxGap` of 80–120 px on slow swipes (vs 7–60 on fast swipes), which means at threshold 15 the slow-motion mask is *severely* fragmented inside the moving body. Two non-mutually-exclusive root causes for the fragmentation:
  - **Mid-body cancellation (spec 2.3 prediction).** Pixels in the interior of the moving body have nearly identical luma between frames N-1 and N, so `|Δ|` falls below 15 and the interior goes blank. This is *correct* behavior for frame differencing — what the spec predicts.
  - **Texture-poor patches.** Even at the leading/trailing edges, smooth-textured patches (uniform shirt, skin) only generate `|Δ| ≥ 15` at the *outline* of those patches, not the patch interior. This produces the "gappy column" pattern the diagnostic logs show.
- **Mid-body cancellation interacts catastrophically with the longest-run picker.** Because the *only* surviving mask pixels in slow motion are near the leading/trailing outline plus a few internal texture bands, "longest contiguous vertical run at the gate column" picks whichever band happens to be longest — which is *not* the leading edge of the body, it's whichever vertical texture stripe is most uniform. This is the root cause of the Y-row picker bias and it's the strongest hypothesis for "early on lower leg" failures.
- **vImage `vImageAbsoluteDifference_Planar8` would be ~3-5x faster** but the current scalar loop is correct and unsafe pointers already remove bounds checks. Not a correctness concern.
- **No morphological closing** before connected components. A single-pixel gap inside the mask creates an extra "hole" that breaks the longest-run count. PF's behavior on slow object tests (S2/S5/S8 — slow objects don't trigger) is consistent with the same fragility, so PF may *also* not do morphology. Don't fix this until we have evidence PF does.
- **No spatial smoothing (e.g. 3x3 blur) before differencing.** A 3x3 blur on the source frame would average out per-pixel sensor noise, allowing a *lower* threshold without false positives. This is a classic CV trick. If we want to drop `diffThreshold` below 15 we should add this first.

### 2.6 Connected components (`DetectionEngine.swift:680-781`)

**What it does.** Standard 8-way union-find, two-pass. First pass labels pixels and unions neighbors; second pass resolves labels and accumulates per-component bounding box + area.

**Concerns.**

- **8-way connectivity means a single diagonal pixel chain bridges two otherwise-separate regions.** This is mostly fine but it can merge an arm and a torso into the same component when they share a diagonal pixel at any single point. With slow motion + gappy mask this is more likely than it sounds. **For our "leg and torso fire as one component" failure mode, this is the structural reason `body_part_suppression` doesn't fire** — the leg isn't a separate component, it's a sub-region of the same component as the torso.
- **No size cap on the components array.** A pathological frame with 50 000 small components would allocate ~50 000 `Component` structs (`compBuf` is sized to `count/4 + 256`). This is fine in practice but uncapped.
- **Component statistics are bounding boxes, not actual masses or shape descriptors.** The downstream filters (height/width/fill/aspect) only see W, H, area, minX..maxX, minY..maxY. They cannot tell a "U-shaped" component from a "filled rectangle" except via fill ratio.

### 2.7 Per-component prefilters (`DetectionEngine.swift:235-256`)

| filter | code | spec match? |
|---|---|---|
| `comp.height ≥ 105` (33%) | `DetectionEngine.swift:236` | Spec 4.1 says ~30%; we're at 33%. **9px gap.** |
| `comp.width ≥ 14` (8%) | `DetectionEngine.swift:240` | Spec 4.2 says ~8%. Match. |
| `fillRatio ≥ 0.25` | `DetectionEngine.swift:244-248` | **Not in spec.** Added defensively. |
| `width ≤ 1.2 × height` | `DetectionEngine.swift:249-252` | **Not in spec.** Added defensively. |
| component straddles `gMin..gMax` | `DetectionEngine.swift:253-256` | Spec 3.2 step 5. Match. |

**Concerns.**

- **`heightFraction = 0.33` is biased ~10% over PF's "approximately 30%".** A blob of height 100 (31% of 320) is close enough to PF's threshold to plausibly trigger PF but is rejected by us. On real bodies this won't matter (a runner is much taller than 33%), but for partial-occlusion poses (entering frame, lean, head out of frame) we may reject crossings PF accepts. **Recommend lowering to 0.30 if Test F shows missed real-body crossings with `[REJECT] height` between 96 and 105.**
- **`fillRatio ≥ 0.25` will silently kill slow real-body crossings.** Reasoning: frame differencing produces edge pixels, not filled silhouettes. A torso that's 100×260 has bbox area 26 000, but the actual mask coverage is mostly the leading and trailing edges plus shirt-texture stripes — easily under 0.25 for a uniform-shirted runner against a uniform background. **Test E.2 (slow swipes) showed dozens of `fill_ratio` rejects in the 17-second gap between crossings 4 and 5; this is *exactly* the failure mode.** PF is known to handle slow crossings (it has a too-slow region but our slow-swipe range is well above that), so PF either doesn't have this filter or has a much lower threshold.
- **`maxAspectRatio = 1.2` is too tight for finish-line leans.** A runner finishing with a hard forward lean compresses the silhouette vertically and stretches it horizontally. From the diff mask the bbox can briefly be wider than tall. PF reportedly handles forward leans (spec 6.2) and even has a documented "lean ladder" inferred behavior (spec 13.2D). We will reject those frames. **Test history doesn't have lean data yet — but I expect the next real-body run to show `[REJECT] aspect_ratio` on lean frames.**
- **The order of prefilter checks matters for the log.** Currently height → width → fill → aspect → gate intersection. The first reject wins, so a tall *and* sparse blob will only ever log "fill_ratio" — we never see "this would also have failed aspect". Fine for the current pipeline but it makes triage of edge cases harder.
- **Width prefilter being `0.08 × W = 14 px` matches PF, but the broomstick test (PF S9, 2026 test 1) showed PF rejects broomsticks "<8% of frame width."** Our 14-pixel cutoff is right at the line. We've never tested a broom-thin object on our app.

### 2.8 Gate intersection (`DetectionEngine.swift:253-256`)

**What it does.** Component bbox must overlap `gMin..gMax = 88..92`. This is a 5-column band, not a single column. PF spec 13.2B explicitly lists single-column-vs-narrow-band as an unresolved question.

**Concerns.**

- **5-column band is wider than PF *might* be.** If PF is single-column, we'll fire on objects that PF wouldn't because they only graze the gate. We have no way to distinguish until Phase 1 / Phase 3 PF parallel data lands.
- **Gate band check is on the *bounding box*, not on actual mask pixels at the gate columns.** A U-shaped component whose bbox spans the gate but whose actual mask pixels miss the gate columns will pass this check and then get caught by `analyzeGate` (which scans the actual columns). Fine but slightly wasteful.

### 2.9 `analyzeGate` — leading-edge local-support scoring (`DetectionEngine.swift:789-882`)

**This is the most important function in the detector and the most likely source of the current failure modes.** Walk it carefully.

```
1. minSupport = max(3, 0.25 × comp.height, 0.08 × 320 ≈ 25)
2. columns = [88, 89, 90, 91, 92]   // 5 columns from gMin..gMax
3. For each column gx:
     longest = longest contiguous run of mask=1 in y ∈ [comp.minY, comp.maxY]
     mid     = midpoint y of that longest run
     colRuns[ci] = longest
     colMids[ci] = mid
4. compCenterX = (minX + maxX) / 2
   movingRight = compCenterX < gateColumn   // LEADING EDGE on the right
5. sw = 3 (sliceWidth), windowCount = 5 - 3 + 1 = 3 windows
6. windowIndices = (movingRight ? reverse : forward)
7. For wi in windowIndices:
     avgRun = sum(colRuns[wi..wi+sw]) / sw
     avgMid = sum(colMids[wi..wi+sw]) / sw
     if avgRun ≥ minSupport: return (yes, detectionY=avgMid, run=avgRun)
8. return (no, ...) — overall best window kept for diagnostics
```

**Concerns — and this is where the leg/wrist/heel bias lives.**

#### 2.9.1 `colRuns[ci] = longest run inside the *whole* blob`

The per-column `longest` is computed over `comp.minY..comp.maxY`, i.e. the full vertical extent of the blob. **There is no preference for runs near the leading edge in Y.** If the blob is a runner with a shin-band of clean motion at y=250..305 and a fragmented torso-band at y=70..220, the per-column longest will pick the shin-band every time. The window sees 5 columns of "longest run is at y≈278" and reports `detY=278`.

This is structurally identical to the failure mode Tests A/B/C documented: the detector picks the densest stripe, not the leading body part.

**The "leading edge" branch in step 6 only orders the X scan**, not the Y scan. Inside any single column, the leading edge in Y is *not* preferred. The code is named "leading-edge scan" but it only does leading-edge ordering across X — Y is still pure "longest run anywhere".

#### 2.9.2 Sliding window averages midpoints, not Y consistency

`sumMid += colMids[j]` and then `avgMid = sumMid / sw`. **This is a Y-consistency disaster when the per-column longest runs are at different Y positions.**

The Test C documented case:
- `c88: longest at y=197..239, mid≈218`
- `c89: longest at y=197..238, mid≈217`
- `c90: longest at y=262..305, mid≈283`  ← from a totally different body region
- `avgMid = (218 + 217 + 283) / 3 = 239`  ← this is *between* the two regions, where there's no mask at all

The detector reports `detY=240` on a frame where no column had a pixel at row 240. The user sees the yellow dot land in the gap between the leg and the torso. **This is bug #2 in the TL;DR and it is real, geometric, and reproducible.**

#### 2.9.3 The `avgRun` threshold doesn't care about disjoint runs

`avgRun = (col0_run + col1_run + col2_run) / 3 ≥ minSupport` lets a 1-of-3 or 2-of-3 column with a strong run override columns that have nothing. This was deliberate ("graded score, doesn't kill the window on one weak column") but it creates the disjoint-mid problem above.

**A consistency check** — e.g. require that the per-column longest runs have at least N px of Y overlap, or that the standard deviation of midpoints is < some bound — would fix the disjoint case directly. But it's a code change, so it's documentation only here.

#### 2.9.4 `minSupport` floor of `0.08 × H = 25.6 ≈ 25 px` may be too low

For a tall blob (h=258), `need = max(3, 64, 25) = 64`. For a shorter blob (h=120, hand swipe), `need = max(3, 30, 25) = 30`. Test D close-misses showed `need=29..31, avg=22..29` — i.e. hands are sitting *right on* the boundary, so any small mask perturbation flips the verdict. This explains the noisiness of "did the hand swipe trigger or not?" between Test D and Test E.

For real bodies the 64 floor is more meaningful because it scales with blob height. But it still means a 64-px clean shin run beats a 60-px gappy torso run, every time.

#### 2.9.5 Hand-swipe close misses are the wrong failure mode anyway

Per the spec (PF tests S2/S5/S6/S8 — slow movement doesn't trigger), PF rejects slow hand swipes. So if we miss a slow hand swipe, we may actually be matching PF behavior. The Test E.2 "many missed crossings" observation could be *correct* — we don't have a PF parallel reference yet to know.

**This means the most important confound right now is that we're trying to tune against hand swipes when PF doesn't even claim to detect them reliably.** Real-body data is the only thing that anchors what "correct" looks like.

### 2.10 Best-component selection (`DetectionEngine.swift:259-263`)

```swift
if best == nil || comp.area > best!.comp.area {
    best = (comp, ...)
}
```

**What it does.** When multiple components qualify, pick the one with the largest area.

**Concerns.**

- **Largest area is not the same as "the one whose leading edge is at the gate".** For real bodies where the entire person is one component this is fine. For two-runner scenarios (deferred from PF spec 13.4) it's incorrect — we'd pick the larger body, possibly the trailing one. PF spec is silent on this; we'd need PF parallel data with two runners.
- **No tie-breaking on direction.** Two components moving opposite directions, one larger, one smaller — we pick larger, which may be moving *away* from the gate. The body-part suppression sweep below catches some of this, but not all.

### 2.11 Body-part suppression (`DetectionEngine.swift:285-301`)

```swift
for comp in components {
    guard comp.height >= minH, comp.width >= minW else { continue }
    guard comp.area > candidate.comp.area else { continue }
    guard comp.maxX < gMin || comp.minX > gMax else { continue }
    let distToGate = comp.maxX < gMin ? (gMin - comp.maxX) : (comp.minX - gMax)
    if distToGate <= 36 { return nil }   // approachZone = 0.20 × W
}
```

**What it does.** Iterates all components. If any *other* size-qualified component is larger, doesn't touch the gate, and is within 36 px of the gate, suppress the current detection and wait.

**Concerns — this suppression is structurally weak in three different ways.**

1. **Same-component case is invisible.** The leg + torso of a real runner are usually the *same* connected component (8-way connectivity, gappy mask, occasional diagonal bridges). The suppressor only fires when there's a *separate* larger component near the gate. **For the leg-fire failure mode this means suppression silently never activates** because there is no separate torso component to compare against.
2. **No direction check.** A larger component on the gate's "behind" side moving *away* from the gate still triggers suppression. Per the audit notes, this should fire only when the larger blob is *approaching* the gate. The fix would need a per-component velocity estimate (compare to previous frame's components) which we don't have.
3. **`approachZone = 36 px = 20% of W` is wider than the gate band itself (5 columns).** A real run can have an arm 30 px out from the gate while the torso is exactly at the gate; the arm gets selected as the gate-touching candidate, and a larger (non-gate-touching) body component within 36 px will suppress it. Net: nothing fires that frame, the runner advances 5–10 px, the next frame fires on the now-overlapping torso. This may be why Test A had a few "too late, full body" cases instead of consistent "early on leg" — when the suppressor randomly fires, it shifts the detection one frame *late* instead of *early*.

**Test history confirms the suppressor is barely active.** Test A: zero `body_part_suppression` rejects (despite 13/21 leg-fires). Test D: zero. Test E.1: one event on frame 196 (gate_area=4367, approaching_area=4846, dist=11 — borderline case). Test E.2: zero.

**The fact that the suppressor never fires when we want it to is consistent with bug #1 (same-component case).** It's also consistent with bug #2 (no direction check) — many of the suppression events that *would* fire are correctly being skipped because the larger blob is the trailing arm/leg, not the approaching torso. We can't tell which until we have logging on it.

### 2.12 Position-based interpolation (`DetectionEngine.swift:303-343`)

```
detRow = candidate.detY
runLeftX = scan left from gateColumn while maskBuf[detRow*W+x] != 0
runRightX = scan right
movingLeftToRight = compCenterX <= gateColumn
if movingLeftToRight:
    dBefore = gateColumn - runLeftX
    dAfter  = runRightX - gateColumn
else:
    dBefore = runRightX - gateColumn
    dAfter  = gateColumn - runLeftX
fraction = dBefore / (dBefore + dAfter)
crossingTime = prevSec + fraction*dt - start
```

**What it does.** Uses the contiguous horizontal run of mask pixels at `detRow` (the detection Y row) as a stand-in for "leading edge position in frame N-1 vs frame N". `dBefore` is how far the old leading edge was from the gate; `dAfter` is how far past the new leading edge went.

**Concerns.**

- **`detRow` is the buggy `detY` from `analyzeGate`.** If `detY` is on the shin, the horizontal-run scan happens on the shin row, where the body's left/right extent is *much* narrower than at the torso. So even if the *Y* picker were fixed independently, the X interpolation depends on it.
- **The horizontal scan walks *all* mask pixels at `detRow`, including motion that's not from the same component.** A leg in one component and a separate noise blob at the same Y row would both contribute to `runLeftX/runRightX`. There's no "are these pixels actually in `candidate.comp`" check.
- **The contiguous-run logic assumes the leading edge of the mask is at the run's far end, but for a frame-diff mask there are *two* edges per body** (leading and trailing). At slow speeds the two edges are close together and the run does represent the body. At higher speeds they're far apart and the run might span across an interior gap, *or* it might capture only the leading edge (with the trailing edge as a separate disconnected run). The current scan picks whatever's contiguous *through* the gate column, which is usually the right thing but not always.
- **Direction inference from `compCenterX` is wrong for narrow blobs straddling the gate.** A blob with `minX=85, maxX=95, gateColumn=90, compCenterX=90` has `compCenterX <= gateColumn` → "moving L→R". For a centered blob at the moment of crossing, the *center* doesn't tell you direction. PF spec says the app handles both directions correctly (test 20 — back-and-forth). We're inferring direction from a single-frame snapshot, which is not robust. **A frame-to-frame velocity estimate (compare current `compCenterX` to previous) would be the right fix, but it's deferred.**
- **Direction correctness flips dBefore/dAfter assignment.** If we get direction wrong, the *fraction* is also wrong (1 - frac), and the resulting timestamp is off by `(1 - 2*frac) * dt`. For symmetric crossings (frac ≈ 0.5) this is small. For lopsided ones it can be a full frame.
- **`fraction = dBefore / (dBefore + dAfter)` becomes 0/0 when both are zero.** Code defaults to 0.5. This happens for tiny blobs that just barely touch the gate column. Fine.

### 2.13 Exposure correction (`DetectionEngine.swift:346-349`)

```swift
if let exp = exposureDuration ?? previousExposureDuration {
    let expSec = CMTimeGetSeconds(exp)
    if expSec > 0.002 { crossingTime += 0.75 * expSec }
}
```

**What it does.** Adds `0.75 × exposure_duration` if exposure > 2 ms. Direct from PF paper (spec 7.3).

**Concerns.**

- **2 ms threshold isn't in the PF paper.** The paper says PF *always* adds 0.75 × exposure. We added a floor to suppress the correction in bright daylight. For low-light tests this is irrelevant; for bright daylight the correction would be ~0.75 × 0.5 ms = 0.375 ms (negligible). **This deviation from spec doesn't matter for accuracy but it's a place where our app and PF behave differently.** If a PF parallel test shows a consistent bright-light offset of ~0.4 ms, this is the cause.
- **Uses current exposure if available, otherwise previous.** This is a *current* frame correction. The interpolation between N-1 and N gets the same correction added regardless of where in the sub-frame interval we landed, which is consistent with the paper.
- **`exposureDuration` from `device.exposureDuration` may lag the actual frame's exposure.** AVFoundation reports the *current* device exposure setting at the moment we read it, not the exposure used for the specific sample buffer we just got. With the 4 ms cap pinned (front cam), this is fine. With auto-exposure changing rapidly, the correction could be off by one frame's worth of adjustment.

### 2.14 Thumbnail frame selection (`CameraManager.swift:494`)

```swift
let usePrevious = result.interpolationFraction < 0.5 && previousPlaneCopy != nil
```

**What it does.** Picks frame N-1 if the crossing happened earlier in the sub-frame interval, otherwise frame N.

**Concerns.**

- **Symmetric tie-break** at `fraction == 0.5`: prefers current. Fine.
- **The `< 0.5` cutoff is a *closest-frame* heuristic, not a "frame in which the crossing was visually correct" heuristic.** For a runner with `fraction = 0.4`, the crossing happened 40% of the way between N-1 and N. Frame N-1 is 0.4 of the interval *before* the crossing; frame N is 0.6 *after*. The closer frame is N-1 (distance 0.4 < 0.6). Correct.
- **The thumbnail user sees may be 33 ms before or after where PF would show its dot.** Not a detector bug, but it confounds visual comparison: if our `detY` picks the shin in frame N-1 and PF picks the torso in some other frame, the visual mismatch is partly the picker bug and partly the frame choice.

### 2.15 Cyan/yellow overlay rendering (ContentView, not analyzed here)

Out of scope for this analysis but worth flagging: the cyan line and yellow dot are rendered from `gateY = detY` and `interpolation fraction → shiftedLayoutX`. Any bug in `detY` immediately becomes a visible bug in the overlay. The user sees what the algorithm sees.

---

## 3. Spec deviations table

A condensed list of every place our code does something the spec doesn't say to do, or doesn't do something the spec says to do.

| # | Spec rule | Spec section | Our implementation | Deviation? |
|---|---|---|---|---|
| 1 | Frame diff N vs N-1 | 2.1 | Same | ✅ match |
| 2 | Width ≥ 8% | 4.2 | `widthFraction = 0.08` | ✅ match |
| 3 | Height ≥ ~30% | 4.1 | `heightFraction = 0.33` | ⚠️ slightly stricter |
| 4 | Single connected component | 4.1 | 8-way union-find | ✅ match (but 8-way may over-merge) |
| 5 | Gate region exact width | 3.1 | 5-column band 88..92 | ❓ unknown if PF is single-column |
| 6 | Leading-edge / locally substantial slice | 6.2-6.3 | `analyzeGate` longest run | ⚠️ does X-leading but not Y-leading |
| 7 | Body-part suppression | 6.4 | `body_part_suppression` sweep | ⚠️ structurally weak (same-comp invisible) |
| 8 | Linear interpolation between N-1 and N | 7.1 | Position-based via mask scan | ⚠️ approximation, not direct edge measure |
| 9 | Exposure correction `0.75 × exp` | 7.3 | Same, with 2 ms floor | ⚠️ floor not in spec |
| 10 | 30 fps | 7.2 | Locked 30 fps | ✅ match |
| 11 | All auto camera | 7.2 | Auto with 4 ms exposure cap | ⚠️ cap not in spec, intentional sharpness fix |
| 12 | 0.5 s cooldown | 9.1 | `cooldown = 0.5` | ✅ match |
| 13 | Shake/motion via accelerometer | 8.1 | CMMotion with 0.15 m/s² threshold | ✅ match |
| 14 | Min speed (rejects very slow) | 5.1 | No explicit speed filter; emerges from `fillRatio + diffThreshold` | ⚠️ implicit, not modeled |
| 15 | Both directions | 3.3 | `windowIndices` reversal | ⚠️ untested, asymmetric scan order |
| 16 | Pure geometry, no torso classifier | 6.1 / inf 4 | No classifier | ✅ match |
| 17 | `fillRatio ≥ 0.25` | — | Yes | ❌ **not in spec** — added defensively |
| 18 | `maxAspectRatio ≤ 1.2` | — | Yes | ❌ **not in spec** — added defensively |
| 19 | Warmup skip 10 frames | — | Yes | ❌ not in spec; pragmatic |
| 20 | Closest-frame thumbnail pick | — | `usePrevious if frac < 0.5` | ❌ not in spec; UI-only |

The four "❌ not in spec" items are intentional defensive additions. They were added for hand-swipe rejection in early sessions, before we had real-body data. **Two of them (17 and 18) are now suspect because they may reject real bodies under load.** Specifically:

- `fillRatio ≥ 0.25` will reject any low-contrast slow runner.
- `maxAspectRatio ≤ 1.2` will reject hard finish-line leans.

We have NO test data on either failure mode yet.

---

## 4. Failure-mode hypotheses by scenario

This is the part the user explicitly asked for. For each scenario, I'm listing what I expect to fail, why, where in the code, and what diagnostic evidence would confirm it.

### 4.1 Slow crossing (walking pace, jogging)

**Predicted failure modes:**

| likelihood | failure | mechanism | code site | confirming diagnostic |
|---|---|---|---|---|
| **High** | `[REJECT] fill_ratio` for several frames in a row, then a late detection | Slow torso through frame diff = mostly leading/trailing edges + interior texture stripes; `area/(W*H)` falls below 0.25 | `DetectionEngine.swift:244-248` | Repeated `[REJECT] fill_ratio` lines, ratios 0.10–0.24, areas 4000–8000, in the 200 ms before a successful detection |
| **High** | Detection fires 1–3 frames late on the *trailing* edge | Mid-body cancellation leaves only edges; `analyzeGate` picks the trailing-edge run if it's locally longer than the leading-edge run | `DetectionEngine.swift:801-819` | `[DETECT_DIAG]` columns with `lng@sY..eY` where the run is at the *back* of the blob (eY closer to leading edge than sY+lng) |
| **Medium** | `body_part_suppression` fires on phantom blobs and silently kills good detections | Slow motion produces noise blobs that are *larger* in area than the real candidate but in a different X position | `DetectionEngine.swift:285-301` | `[REJECT] body_part_suppression` with `gate_area < approaching_area` where neither is the real torso |
| **Medium** | `[REJECT] aspect_ratio` on a frame where the runner has just one foot down | Single-leg-stance blob can briefly be wider than tall in the diff | `DetectionEngine.swift:249-252` | `[REJECT] aspect_ratio` with `w=120 h=100 ratio=1.2` close to a successful detection |
| Low | The 0.5 s cooldown swallows a real second crossing | Two slow runners 0.4 s apart | `DetectionEngine.swift:194-197` | Missing crossing where one was visually present; no `[DETECT]` log line |

**Strongest evidence to look for after the test:** in the log around any "missed slow crossing", the count of `[REJECT] fill_ratio` lines and their `area=` values. If we see 5+ frames of `area=4000-8000 ratio=0.10-0.24` followed by a detection on the *next* frame, the fill-ratio filter is the main culprit and we should verify whether dropping it (or moving to `≥ 0.15`) would have caught the right frame.

### 4.2 Leg swipes / lower-leg-leading poses

This is the **single most-confirmed failure mode** in our test history (Test A: 13/21 crossings reported as leg-fires).

**Predicted failure modes:**

| likelihood | failure | mechanism | code site |
|---|---|---|---|
| **Very high** | `detY` lands on the shin instead of the torso | The shin is fully vertical at the gate, has clean `|Δ|` along its length, and produces the longest contiguous vertical run in the gate columns; `analyzeGate` picks it | `DetectionEngine.swift:807-819` (per-column longest), `855-867` (window pick) |
| **Very high** | The detected crossing is timestamp-correct for the *shin*, which is ahead of the torso, so the timer fires "early" | Geometry + interpolation are correct given the wrong `detY` | `DetectionEngine.swift:303-343` |
| **High** | `body_part_suppression` does NOT fire because the leg and torso are the same connected component | Diagonal pixel bridges merge them in the 8-way components pass | `DetectionEngine.swift:680-781` (8-way), `285-301` (suppression sweep) |
| Medium | `[REJECT] aspect_ratio` for the torso component when shin is the only thing fully at the gate | Torso bbox is wide (arms swinging) but the actual gate-touching part is narrow; we measure bbox aspect, not gate-slice aspect | `DetectionEngine.swift:249-252` |
| Low | PF actually accepts "fully vertical shin" too (test 15b) and our app is matching PF on the strict-vertical case while still being wrong on partially-vertical legs | This would mean some leg-fires are CORRECT per PF, others are bugs | spec 6.2 + raw test 15b |

**The PF spec (6.2 + 13.2E) explicitly says:** "leg/foot-leading outcomes currently appear to depend heavily on whether the pose creates a tall enough vertical blob; there is no good evidence yet for any special treatment of the lower part of the frame". **This means we cannot conclude every shin-fire is a bug — some are emergent from the same geometry rule and PF would also fire on them.** The bug is the cases where the shin is *not* fully vertical (e.g. mid-stride with bent knee) and we still fire on it because the longest run picks a sub-segment of a non-vertical leg.

### 4.3 Leaning body / forward finish-line lean

**Predicted failure modes:**

| likelihood | failure | mechanism | code site |
|---|---|---|---|
| **High** | `[REJECT] aspect_ratio` for frames where the runner is at maximum lean | `width > 1.2 * height` for compressed silhouettes | `DetectionEngine.swift:249-252` |
| **High** | `detY` lands too far back inside the torso (matches PF's "rare backward drift on stronger leans" — spec 13.2D) | The leading slice is slivery; `analyzeGate` picks a more-substantial slice further back | `DetectionEngine.swift:807-867` |
| Medium | `body_part_suppression` fires on the head/neck appearing as a separate component above the torso | Head + torso connected mask sometimes fragments at neck | `DetectionEngine.swift:285-301` |
| Medium | Detection fires on the wrong frame because cooldown swallowed the first valid frame | Multi-frame lean approach can produce two detections close together | `DetectionEngine.swift:194-197` |
| Low | `comp.area > best!.comp.area` picks a non-leading component when the lean creates an arm component that's accidentally larger | Multiple gate-touching blobs with bbox confusion | `DetectionEngine.swift:259-263` |

**Note that the "backward drift on lean" failure mode is *also predicted by the PF spec* as something PF itself does** (spec 13.2D). So a test that shows our detY drifting back on stronger leans would not necessarily distinguish "we have a bug" from "we are matching PF". We need PF parallel data to disambiguate.

### 4.4 Hand swipes (carry-over from Tests B/C/D/E)

Already heavily tested. Documented failure modes:

1. **detY lands on the densest mask region** (heel of palm, wrist, etc.) — Tests B/C/E showed Δy of −37 to −128 px. Same root cause as leg swipes.
2. **Disjoint-range averaging** — Test C #1 and #6 showed window-averaged midpoint landing in a Y-zone with no mask. Same code site (`DetectionEngine.swift:855-867`).
3. **Slow swipes barely clear `localSupportFraction`** — Test D close-misses `need=29..31, avg=22..29`. Hands are right at the boundary.
4. **Fast swipes have noisy fraction distribution** — Tests B/D/E.1/E.2 show three different bias directions. **Per the spec, this may be irrelevant** because PF may also reject hand swipes. We need PF parallel data.

**No new hypotheses for hand swipes that aren't already in the test_runs file.** This analysis adds the structural code-site mappings.

### 4.5 Low-light conditions

**Predicted failure modes:**

| likelihood | failure | mechanism | code site |
|---|---|---|---|
| **High** | Increased sensor noise pushes `|Δ| ≥ 15` for noise pixels too, creating spurious blobs | `diffThreshold = 15` was set with bright-light noise floors in mind | `DetectionEngine.swift:202-220` |
| **High** | Auto-exposure pushes shutter to 33 ms; motion blur widens the leading edge into a fat blob; `analyzeGate` picks the densest blur stripe | Long shutter = wide motion smear | spec 7.2 + `applyExposureSettings` 4 ms cap |
| **Medium** | Exposure correction `0.75 × 33 ms = 25 ms` becomes the dominant timing component, overwhelming the interpolation | Per spec 7.3, this is *correct* PF behavior in dim light | `DetectionEngine.swift:346-349` |
| Medium | `[REJECT] body_part_suppression` fires more often because noise blobs are larger | Noise area grows in low light | `DetectionEngine.swift:285-301` |
| Low | Frame drops increase because the diff loop has more "set" pixels to label | More mask pixels = more components = more work | `DetectionEngine.swift:680-781` |

**Our 4 ms exposure cap (`maxExposureCapMs: Double? = 4.0`) keeps motion blur low but pushes ISO to 1100–1900 in dim conditions** (Test D logs). At ISO 1900 noise is significant. We don't currently see noise-driven false fires in the logs, so the `diffThreshold=15` floor seems to be holding. But the cap is itself a deviation from PF (PF uses fully-auto exposure with no cap).

### 4.6 Frame drops / timing stalls

**Already documented:** the cold-start `[FRAME_DROP] 16` after the first crossing in every recent test. This is the vImage thumbnail allocation cost on first call. The `prewarmThumbnail` pre-warm helps but doesn't fully eliminate it.

**Risk for next real-body run:** if two crossings come within ~600 ms, the second one may land inside the cold-start drop window and never fire. **This is the most likely cause of "we missed crossing #2 on a fast back-to-back" if it happens.** Mitigation already in place (prewarm), full fix is deferred.

### 4.7 Direction asymmetry (L→R vs R→L)

**Predicted failure modes:**

| likelihood | failure | mechanism | code site |
|---|---|---|---|
| **Medium** | `windowIndices` reversal for R→L scans the leading edge first, but no test has R→L in numbers high enough to compare | Tests A/B/C/D mostly L→R; only Test E.1 had 2 R→L out of 10 | `DetectionEngine.swift:833-838` |
| **Medium** | Direction inference from `compCenterX` is wrong for centered blobs at the exact moment of crossing | Single-frame snapshot of position, not velocity | `DetectionEngine.swift:323-324` |
| Low | Front-camera mirror in `connection.isVideoMirrored = true` flips the buffer; we're reading post-mirror coordinates and the algorithm should work identically | If mirroring were broken, every front-cam test would be wrong | `CameraManager.swift:319` |

**Recommend:** in the next run, deliberately mix L→R and R→L crossings in equal proportion. If detY/fraction biases differ between the two, direction asymmetry is real.

### 4.8 Two runners / close gaps

**Untested.** Cooldown of 0.5 s means any second runner under 500 ms behind the first is silently dropped. PF is also reported to have ~0.5 s cooldown so this is "match PF" not "bug" — but it means we cannot time a 4×100 m relay handoff at all.

### 4.9 Phone instability / mid-session bumps

`isPhoneStable` going false silently kills detection for 0.75 s after the bump stops. **No log line indicates this.** If the user reports "detection stopped working after I tapped the screen", this is the cause. Adding a `[STABILITY]` log line on every transition would help triage but isn't done.

---

## 5. Cross-checks against the academic paper

The Photo Finish paper (Voigt et al., 2024) gives some quantitative anchors that we can sanity-check our implementation against.

| Paper claim | Our app | Match? |
|---|---|---|
| 30 fps on all phones | locked 30 fps | ✅ |
| Linear interpolation between two frames | position-based mask interpolation | ⚠️ approximation (we use mask run, not edge distance) |
| Adds `0.75 × exposure_duration` | same, with 2 ms floor | ⚠️ floor not in paper |
| Triggers "between middle and end of blurred image section" | detY = midpoint of longest run, which sits inside the densest part of the blur | ⚠️ may align with paper or may be biased — depends on which subsegment is densest |
| Camera timestamps = beginning of exposure | iOS gives us PTS at start of exposure | ✅ |
| 75th percentile accuracy: 10 ms | unknown — we have no PF parallel data yet | ❓ |
| 95th percentile accuracy: 14–15 ms | unknown | ❓ |
| Optimal phone distance 1.4–1.6 m | UI gives no guidance | ⚠️ irrelevant to detector |
| Portrait orientation only | enforced by `videoRotationAngle = 90` + transpose path | ✅ |

**The most interesting paper claim is "triggers between middle and end of blurred image section".** This is critical because it tells us PF *doesn't* aim for the leading edge of the blur — it aims for somewhere in the middle-to-end of it. This could mean our `analyzeGate` "longest run midpoint" is *closer to PF behavior than the alternative "topmost qualifying run"*. **The Test C +Δy outlier (#8, +11) and the variable bias direction across runs is consistent with this**: PF wouldn't aim for the leading edge either.

**This is a major caveat to the "fix the Y picker by preferring the topmost run" hypothesis** that has been floating around. Before doing that, we need PF parallel data to confirm where PF actually picks within the blur.

---

## 6. Fingerprinted test predictions

These are concrete things to look for in the next physical test that, if observed, would confirm or refute specific hypotheses without requiring code changes.

### 6.1 Real-body crossings (the big one)

**Setup:** real walking + jogging + running passes through the gate, mix of L→R and R→L, mix of distances. Tap-mark each crossing with the user's finger on the visual leading edge.

**Predictions:**
1. **`detY` will land in the lower 30% of the blob on most jogging crossings** — confirming the longest-run picker prefers the densest region (leg/lower torso).
2. **`Δy = userY - detY` will be negative** for most crossings, with magnitude 30–80 px (similar to hand-swipe Δy).
3. **`fraction` will be roughly uniform** across crossings, mean ≈ 0.5, IF the X interpolation isn't broken on real bodies.
4. **`[REJECT] fill_ratio` will appear several times in the lead-up to many slow crossings**, with `ratio` in 0.15–0.24 range. If this fires *during* the actual crossing frame and not before, it's the failure mode.
5. **`[REJECT] aspect_ratio` will appear on at least one lean frame.** If a runner finish-line dives, expect 1+ rejects on the lean frame.
6. **`body_part_suppression` will rarely fire**, because torso+limbs are usually one component on real bodies.
7. **The disjoint-range artifact (Test C #1/#6) will appear on at least one real-body crossing**, visible as a `DETECT_DIAG` line where two of the three winning columns have runs at totally different Y positions.
8. **R→L crossings will look subtly different from L→R**, with detY at slightly different relative positions in the blob — but we don't yet know which direction.

### 6.2 Same-pose lean ladder

**Setup:** same person, same speed, increasing forward lean (upright → slight → moderate → extreme).

**Predictions:**
1. The relative `detY` (within the blob) will drift backward (downward in process Y, since lean tilts the leading edge low) as the lean increases — matching PF spec 13.2D.
2. At maximum lean, at least one frame will fail `aspect_ratio`.
3. `comp.area` will *decrease* as lean increases (vertical compression), possibly tripping the `comp.area > best.comp.area` tie-breaker in unhelpful ways.

### 6.3 Vertical shin test

**Setup:** stand still, then push one leg vertically forward through the gate without moving the torso.

**Predictions:**
1. **The leg will fire as a detection** (consistent with PF test 15b — PF also fires on truly vertical shins).
2. `detY` will be in the lower half of the frame.
3. **No `body_part_suppression`** will fire (torso isn't moving, so no large competing component exists).

### 6.4 Bottle ladder (object control)

**Setup:** same bottle, multiple orientations, same speed/distance.

**Predictions:**
1. As the front slice becomes more slivery, `detY` will drift backward inside the bottle (matching PF spec 6.3, raw test 12g/12h).
2. The rate of drift should be smooth, not abrupt, if our `analyzeGate` is functioning as a graded score (which it claims to be via the sliding-window average).

### 6.5 Cooldown stress

**Setup:** two crossings ~400 ms apart.

**Predictions:**
1. Second crossing is silently dropped (no log line).
2. If it's > 500 ms it fires normally.
3. The cold-start frame drop on the first crossing may also swallow up to 16 frames after it, so the safe gap is more like 1.0 s in the first session minute.

---

## 7. Things we should NOT change before testing

This is here to balance the (long) list of things to suspect.

- **`gateColumn` and `gateBandHalf`** are correct as-is per spec section 3.1. Don't widen or narrow until PF parallel data tells us PF's gate width.
- **`diffThreshold = 15`** is a reasonable noise floor for our scale=4 720p path. Test C suggests it's too high for *slow* motion but lowering it would create false positives in low light. **Don't change this without per-frame noise data first.**
- **`heightFraction = 0.33`** is slightly stricter than spec but the audit's Test D check (look for `[REJECT] height` in 96–105 range) is the right way to validate before changing.
- **`localSupportFraction = 0.25`** is the central tunable for the leg-fire problem, but lowering it would make hand-swipe rejects worse (already barely-passing per Test D). **Tune the *picker*, not the threshold.**
- **`cooldown = 0.5`** matches PF spec.
- **`warmupFrames = 10`** is fine.
- **The 8-way connectivity** is the standard choice and changing it would have wide consequences on every test.

---

## 8. Open questions only physical testing can answer

These are the things we cannot resolve from code review alone:

1. **Is PF's gate single-column or multi-column?** Test 13.2B from the spec.
2. **Does PF's picker pick "leading edge", "middle of blur", or "end of blur"?** Paper says middle-to-end, our code picks "midpoint of longest run", these may or may not match.
3. **What's PF's `detY` position within a real-body blob?** Our hypothesis is "lower than ours" because PF wouldn't fire on legs; the only way to verify is parallel PF capture.
4. **Does PF reject slow hand swipes the way our app does?** PF spec sections 5.1 + S2/S5/S8 say yes, but the boundary speed isn't documented numerically.
5. **Does PF fire on `aspect_ratio > 1.2` blobs (i.e. extreme leans)?** Spec implies yes; our hard cutoff would diverge.
6. **Does PF compute fill ratio at all?** Probably not (not in spec); ours does.
7. **Are PF's `body_part_suppression`-equivalent decisions made on connected components or on something else (e.g. multi-frame blob tracking)?** Spec hedges on this; our component-based approach may diverge in either direction.

---

## 9. Summary — what to do with this document

**This is documentation, not a fix list.** The user's plan is:
1. Run physical tests with the current code.
2. Mark crossings with the on-screen tap.
3. Compare logs against the predictions in section 6.
4. Based on what actually happened (not what's predicted here), pick the *one* highest-impact fix to make.

**My recommendation for what to look at first in the next test log:**
1. **`detY` Y-position relative to blob top** for every real-body crossing. If detY consistently lands in the lower half of the blob on jogging, the Y-picker bug is confirmed.
2. **`[REJECT] fill_ratio` count and area distribution** in the 200 ms before any missed crossing. If fill ratio is killing slow crossings, we'll see it.
3. **`[REJECT] aspect_ratio` on lean frames.** Even one occurrence on a lean confirms the rule is too tight.
4. **`[DETECT_DIAG]` columns for any leg-fire**, looking specifically for the disjoint-range pattern (one column's longest run at Y=200, another column's at Y=280). If we see this on real bodies, the disjoint-range artifact is the dominant problem, not the longest-run picker by itself.
5. **`[FRAME_DROP]` vs crossing density** — if the cold-start drop swallows back-to-back crossings, that's a separate priority.

The single biggest unknown is **whether the Y-picker bias actually transfers to real bodies the way it transfers to hand swipes.** If it does, we have a clear, focused, non-controversial fix to make. If it doesn't, we may have been chasing a hand-swipe-specific problem and the real-body behavior is fine.

End of analysis.

---

## 10. Test F (2026-04-07) follow-up — lean-first investigation order

**Status:** the next physical test was run on 2026-04-07. 17 crossings: 13 upright sprints, 3 forward-lean finishes (laps 14, 15, 16), 1 trailing upright (lap 17). **No leg-swipe / hand-only crossings in this session** — the user explicitly clarified leg-swipe runs are still pending. So this section can confirm or refute hypotheses about real-body upright + lean behavior, but **not** about leg-fire or hand-swipe behavior. Anything else in §0 stays exactly where it was.

Full raw data and DETECT_DIAG excerpts: `test_runs_our_detector.md` § "Run 2026-04-07 Test F". Read that first if you need the per-lap blob dimensions.

### 10.1 What Test F actually confirms

#### Confirmed (promote from hypothesis to observed bias direction)

1. **§0 hypothesis #1 — `detY` lands on the densest mask stripe, not the leading-edge body — IS REAL ON REAL BODIES.** 11 of 12 USER_MARK'd laps have negative Δy (detector pick is *below* user's torso mark, deeper into the body toward feet). Mean Δy ≈ **−47** (≈14.7% of frame height). Worst three offenders: **−122, −116, −105**. This was previously only seen on hand swipes (Tests B, C, parts of E); we now have real-body confirmation. The Y-row picker is the dominant source of "where is the dot drawn" error, and the bias direction is downward (toward feet).

2. **§0 hypothesis #2 — sliding-window averaging across disjoint Y-runs — IS REAL ON REAL BODIES.** Lap 9 produced exactly the predicted column split:
   ```
   c88: lng=146 @ 140..285   ← torso/leg block, midpoint ≈ 212
   c89: lng=136 @ 143..278   ← torso/leg block, midpoint ≈ 210
   c90: lng=155 @ 145..299   ← torso/leg block, midpoint ≈ 222
   c91: lng=58  @  46..103   ← head/upper-torso block, midpoint ≈  74
   c92: lng=56  @  47..102   ← head/upper-torso block, midpoint ≈  74
   ```
   `detY = 124` — a y-coordinate where *neither* group's longest run actually had its midpoint. This is the artifact predicted in §0 hypothesis #2 and §2.6, here observed on a jogging body for the first time (not just hand swipes). It produced the only positive Δy in the run (+35) — the picker landed *above* the user's torso mark because it averaged the upper-frame head stripe with the lower-frame leg stripe.

#### Refined (sharpened, not new)

3. **The forward-lean failure mode is the same Y-row picker bug, surfaced through different geometry.** It is **not** "lean reduces vertical height" as a root cause. The picker doesn't care about overall blob height — it cares about which body part the gate column happens to slice at frame T. Existence proofs both directions in the same lean batch:

   - **Lap 14, Δy = −116:** lean produced longest runs at `y=249..319` in every gate column (legs/feet stripe). detY = 283, user marked chest at 167. *Lean as leg-fire.*
   - **Lap 15, Δy = −67:** lean produced one giant 122-px contiguous downward stripe in c88 (`198..319`, ~38% of the frame). detY = 247 = mid-thigh. *Lean as full-body-stripe pick.*
   - **Lap 16, Δy = −5:** lean produced longest runs cleanly in the upper-torso band (`y ≈ 136..209`) with no leg run competing. detY = 166 vs userY = 161. **Most accurate crossing of the entire session, and it's a lean.** *Lean done right.*

   The user's intuition ("leans push detection backwards because vertical height reduces") describes the *symptom* — temporally, the foot crosses the gate after the chest in a forward lean, so picking the foot's vertical stripe lands the detection time later than the chest moment. But the *mechanism* is still the longest-run-in-the-blob picker. Fixing the lean issue and fixing the leg-fire issue are likely the same fix.

4. **Lean does NOT correlate with worse Δy in this run.** Mean lean Δy = −63 (n=3), mean upright Δy excluding the +35 outlier = −55 (n=8). Within sample noise — variance, not bias direction, is what differentiates lean from upright in Test F. **The next test must include parallel PF capture of leans to know whether PF behaves the same way.**

#### Not confirmed, not refuted (no data)

5. §0 hypotheses #3, #4, #5, #6, #7, #8, #9, #10 — no fresh data either way. Test F did not include leg swipes, hand swipes, front-camera runs, low-light runs, two-runner runs, R→L-only runs, or extreme leans beyond the three captured. Leave them ranked as before.

### 10.2 Investigation order (locked in by user instruction)

> "we must isolate one issue at the time for example first forrward lean issue detecting too late cuase the vertical hegiht of the body reduces when i lean forward, we msut check this with photo finsih to try tomatch deteciton, then the next issue to isolate is the leg in front of body issue whcih we msut also solve either sperately or the same time as thesethings could be related"

**Phase A — forward lean.**
1. Run a **parallel Photo Finish session** capturing the same forward-lean scenario. Two phones, same start gun, both aimed at the same finish line. Record both:
   - PF's reported crossing time (its own UI timestamp).
   - Our detector's reported crossing time + USER_MARK on the same physical lean.
2. Compare the two crossing times for each lap. Two outcomes:
   - **(a) PF time matches our time within ±10 ms (≈ ±1/3 frame at 30 fps).** Then PF *also* picks low on leans, the Δy bias is "correct" by PF standards, and the next move is purely visual (move the yellow dot to the chest in the thumbnail UI to match user expectation, but leave the timestamp alone). No detector change needed for the lean issue.
   - **(b) PF time is consistently *earlier* than ours by ~1–3 frames on leans.** Then the Y-row picker is causing real timestamp drift on leans and we need to bias `analyzeGate` toward the topmost qualifying run (or the leading-edge run) instead of the longest run. This is the fix the original `detector_hypotheses.md` predicted.
3. **Do not touch `analyzeGate` until we have the (a)/(b) answer.** Anything else is shooting in the dark.

**Phase B — leg-in-front-of-body.**
4. Once Phase A is resolved: run a leg-swipe / lower-body-only test with parallel PF. Same comparison.
5. **The fix from Phase A may already cover Phase B**, because both failures are downstream of the same `analyzeGate` Y-row picker. Track this explicitly so we don't double-fix or chase a non-issue. Specifically: if Phase A converges on "bias picker toward leading edge / topmost run", run the Phase B regression with that change first, before considering anything new.

### 10.3 Things still NOT to change yet

(Restating §7 of this document for the post-Test-F build, in priority order.)

1. `analyzeGate` Y-row picker — wait for Phase A parallel-PF data.
2. `localSupportFraction = 0.25` — same reason. Touching `need` changes which laps qualify, which changes the Δy distribution, which contaminates the PF comparison.
3. `minFillRatio = 0.25` — Test F shows lap 15 at exactly fill = 0.25 (right at the cutoff). Borderline. But changing it without parallel PF data risks adding false positives we'd then have to debug. Hold.
4. `maxAspectRatio = 1.2` — Test F leans did NOT trigger aspect-ratio rejects (the leans were tall enough), so we have no evidence this filter is biting yet. Hold.
5. `gateBandHalf = 2` (5-column gate band) — held; we want apples-to-apples PF comparison on the current geometry first.
6. `body_part_suppression approachZone = 36 px` — Test F had multi-component gate-touchers on lap 14 and lap 17 but no `body_part_suppression` reject fired in the log (because the leg+torso were the same connected component). Hold; this matches the §0 hypothesis #5 prediction and is unrelated to the lean issue.
7. Cold-start `[GAP] 608ms` + `[FRAME_DROP] 4`/`11` after frame=32 — present in Test F as expected. Separate priority track, not lean-related.

### 10.4 What success looks like for the next test

A "good" next test is the one that distinguishes the (a) and (b) outcomes in Phase A above. Specifically:
- **n ≥ 8 forward-lean crossings** (the Test F sample of 3 is too small for a confident bias direction).
- **Parallel PF reading on every one of those crossings.**
- **USER_MARK on every lap**, not just a subset (Test F had 12 marked of 17 — fine but not ideal).
- Ideally same lighting / same gate distance / same shutter cap as Test F so we can stack the runs.

Until that test exists, the only thing this document can usefully predict is "the lean issue has the same shape as the leg-fire issue, and they will probably be one fix or zero fixes, not two."

End of section 10.

---

## 11. Test G (2026-04-07) follow-up — lean severity correlates one-to-one with picker error, PF does NOT share the bias

### 11.0 What this section supersedes

**§10.2 is superseded by §11 for the Y-row picker question.** §10.2
gated any `analyzeGate` code change on a binary decision: (a) PF's
time matches ours on leans (then the picker is fine relative to PF
and we don't touch it) vs (b) PF's time differs from ours (then the
picker is the bug). Test G makes that decision obsolete for two
reasons:

1. **The user has explicitly ruled T comparison out as the success
   metric.** Direct quote from this session: *"the times wont be
   compareable so its unessary to do this, what mattesr is my
   placement on the thumbnails"*. The success metric for picker
   changes is now **Y-placement on the thumbnail**, i.e. how close
   our dot is to where PF places its dot on the *same blob*, measured
   directly by visual overlay and a tap-on-thumbnail.
2. **Test G has the Y-placement data directly.** On 8 marked
   crossings, the user opened PF and ours side-by-side and tapped
   our thumbnail at the same vertical position PF chose on the same
   physical crossing. The `USER_MARK Δy` column in the Test G table
   is therefore `our_Y − PF_Y` directly, not `our_Y − body_truth_Y`.
   No time comparison is needed — we can read the picker's agreement
   with PF straight off the tap offsets.

The §10.3 "do not touch `analyzeGate`, `localSupportFraction`,
`minFillRatio`, `gateBandHalf`, `maxAspectRatio`, or
`body_part_suppression` until the Phase A data arrives" rule **is
still in force**, but the reason has shifted: it is no longer "we're
waiting on the (a)/(b) answer" (we have that answer), it is now
"the picker fix direction is clear but the exact rule is still
being designed, and we need more `DETECT_DIAG` data before picking
one." See §11.4.

### 11.1 ⚠️ Do NOT pool Test G Δy values with Test A–F

In Tests A–F the on-screen tap marked **body anatomy** (chest /
torso). In Test G the tap marked **where PF placed its dot**. These
are **two different reference axes**. Averaging Δy across both sets
is meaningless and will produce garbage conclusions. Every time you
see a Δy number going forward, check which run it came from.

For the record, governing memory:
`feedback_replicate_not_improve_pf.md` — "the error metric is
(our_Y − PF_Y), not (our_Y − body_truth_Y). USER_MARK / body-anatomy
taps are useful only as a shared reference axis so we can measure
both PF's offset-from-body and our offset-from-body and diff them.
The target is `our_Δy_from_body ≈ PF_Δy_from_body`, not
`our_Δy_from_body ≈ 0`."

### 11.2 Evidence from Test G — what's actually in the run

11 crossings, front camera, mixed lean variations. User-provided
lean labels:
- **More lean (n=5):** crossings #1, #2, #3, #9, #11. All marked.
- **Less lean (n=3):** crossings #4, #5, #10. #4 and #5 marked, #10
  unmarked.
- **No lean (n=3):** crossings #6, #7, #8. #7 marked, #6 and #8
  unmarked. (User labelled #6 as "less lean" verbally at one point
  and "no lean" implied by context at another — see Test G run
  header in `test_runs_our_detector.md` for the authoritative
  labels.)

Marked Δy values:

| # | variation | Δy |
|---|-----------|----|
| 1 | more lean | −76 |
| 2 | more lean | −78 |
| 3 | more lean | −71 |
| 9 | more lean | −86 |
| 11 | more lean | −123 |
| 4 | less lean | −8 |
| 5 | less lean | −3 |
| 7 | no lean | −6 |

**Bimodal split with zero overlap.** More-lean mean Δy ≈ −87;
less/no-lean mean Δy ≈ −5.5. The gap between the two clusters is
~60 pixels — bigger than the standard deviation within either
cluster — on only 8 samples. This is not a subtle statistical signal;
this is a step function.

### 11.3 Hypothesis #1 promotion

**Hypothesis #1 (Y-row picker picks the wrong stripe on leans) is
now promoted one more notch.** Prior state: "plausible; upright
bodies also show the bias, so it may be a shared PF artifact we
shouldn't fix." New state:

> **Hypothesis #1 (confirmed against PF ground truth on this dataset):**
> On forward-lean crossings, our picker lands ~60–120px below PF's
> dot while on upright/less-lean crossings the two agree to within
> ~8px. The divergence is monotonic in lean severity. PF does NOT
> share this bias. **We must close it.**

Mechanism (now supported end-to-end by the DETECT_DIAG data in
`test_runs_our_detector.md` Test G "Mechanism" subsection):
1. `analyzeGate` at `DetectionEngine.swift:789-882` picks the single
   longest contiguous vertical mask run in each of the gate columns
   c88..c92 and averages those run midpoints over a 3-column window.
2. In an upright body, the torso is the tallest contiguous vertical
   structure in the gate column, and it happens to include the chest
   → picker lands on chest → Δy ≈ 0.
3. In a forward-lean body, the torso rotates forward and the gate
   column no longer slices it as a single tall run (shoulder gaps,
   arm gaps, head-forward tilt break it up). The legs remain
   vertical in the gate column and become the longest contiguous
   run → picker lands on legs → Δy ≈ −75..−125.
4. PF keeps its dot in the upper portion of the blob regardless of
   lean severity, which means PF's rule is NOT "longest vertical
   run in gate columns."

Ruling out the naive replacement ("take the topmost third of the
blob"): **crossing #7 in Test G falsifies this.** It is a no-lean
crossing where PF's dot sits at 55% from the blob top, not in the
upper third. So PF's rule adapts to body posture; it is not a flat
fraction of blob height. Whatever we replace the picker with has to
reproduce that adaptability.

### 11.4 Fix direction — committed working model: frame-Y top-weighted gradient

**Working model (committed 2026-04-07):** PF's picker behaves *as if*
every mask pixel in the gate band carries a weight that decreases
smoothly with frame Y — top of frame = high weight, bottom of frame
= low weight. The same gradient drives both behaviors:

- **Where the dot lands.** A frame-Y-weighted centroid of the mask
  in the gate band, pulled upward by the gradient. Body parts at low
  Y dominate; body parts at high Y barely contribute.
- **When the trigger fires.** The gradient-weighted mask sum has to
  exceed a threshold before PF declares a crossing. A leading edge
  at high Y produces a low weighted sum → PF waits → eventually
  upper rows fill in → sum exceeds threshold → fire.

**Evidence chain that pinned this down:**

1. **Test G (front-cam, lean severity sweep).** PF's dot stays in
   the upper portion of the blob across all lean severities while
   ours drops with the longest leg-stripe. Confirmed PF has *some*
   Y-axis bias but did not by itself pin down what kind.
2. **Stomach-lean observation (verbal, 2026-04-07).** PF picks the
   stomach on a stomach-first lean. *Reclassified after the flip
   test below as **neutral / under-powered**:* the stomach sits at
   roughly mid-frame, so a top-down-biased picker would also land
   on it (it's the topmost mask in the gate column at that frame
   moment, since the chest is behind the gate line and not in the
   column yet). The stomach observation does not actually
   distinguish "PF has top bias" from "PF has no Y bias."
3. **Flat-phone flip test (informal, 2026-04-07) — the discriminator.**
   Phone laid flat on a table (so the gravity sensor cannot
   disambiguate "up" and PF's auto-rotation layer falls back to raw
   camera buffer Y). User swept a hand across the gate twice:
   - Right-side-up: leading fingertips at low frame Y → PF fires
     early, on the leading edge.
   - Phone rotated 180° on the table: same physical motion, leading
     fingertips now at high frame Y → PF fires *late*, apparently
     waiting until other parts of the hand reach the low-Y rows of
     the frame.
   The flip inverted the picker's processing axis, and PF's timing
   inverted with it. **This proves PF's bias is anchored to the
   frame Y axis, not to the body's anatomy.** Critical
   methodological note: **the hand was made body-equivalent in
   size** (filling the frame to roughly the same fraction a real
   torso would occupy at gate range), so the flip test is *not* a
   small-mask-only test — it generalizes to body-sized blobs.

**What this rules out and what it leaves open:**

The four discrete picker rules considered in the prior version of
this section ("topmost run by blob fraction", "topmost run by
column-longest fraction", "weighted Y-centroid by run length",
"top-Y + fixed offset") all collapse into special cases or
approximations of the gradient model:

- *Top-Y + offset* (rule 4) is a step-function approximation of a
  gradient with a very sharp cutoff at one Y. Falsified by Test G
  crossing #7 (55%-from-blob-top dot) under the *blob-anchored*
  reading; partially un-falsified under the *frame-anchored* reading
  if we interpret crossing #7 as "top-down scan didn't find enough
  weighted mass until 55% down because of where the body sat in the
  frame at that moment." Either way it's a coarse approximation,
  not the rule itself.
- *Topmost qualifying run* (rules 1 and 2) is a gradient with an
  extreme top-bias and a hard length threshold. Plausible
  approximation, but loses the smooth fall-off behavior that
  explains Test G crossing #7 and the flat-phone "wait for upper
  rows" delay. Approximation, not the rule itself.
- *Run-length-weighted Y-centroid* (rule 3) is the structurally
  closest of the four to the working model — but the prior
  formulation weighted by *run length*, which is blob-anchored. The
  working model weights by *frame Y*, which is frame-anchored. The
  flip test is what forces this distinction. Run-length-weighted
  centroid is therefore *not* the same rule, and is also only an
  approximation.

The working model does **not yet specify the gradient shape**:
linear, exponential, sigmoid, half-weight-Y location, baseline
weight at the bottom. That is the next thing the data needs to
pin down, and it cannot be done from Test F or Test G logs alone
because those logs only summarize the longest run per gate column
— not the per-row mask data the gradient needs to be fit against.

**Why we can't commit to gradient *shape* yet:** our current
`[DETECT_DIAG]` only prints the single longest run per gate column
(`lng=L@Y1..Y2`) plus `tot`/`runs`/`maxGap`. It does NOT print:
- The **topmost mask pixel** in the column (so we can't anchor the
  gradient's high-weight end).
- The **topmost qualifying run** (so we can't read where the
  weighted mass is concentrated).
- The **second-longest run** (so we can't see whether the gradient
  is being anchored by a single dominant stripe or by multiple
  smaller stripes summing together).

Without those, fitting a gradient to Test G data is guessing. The
fix for *that* is in §11.5.

### 11.5 What changes this session, what doesn't

**Changes this session (non-behavioral):**

- `ColStats` / `columnStats` / `logGateDiagPrefix` in
  `DetectionEngine.swift:891-968` are extended to compute and log
  per-column `topmostMaskY`, `topmostRun`, and `secondRun`. The
  existing `lng`/`tot`/`runs`/`maxGap` fields stay in place for
  backward compatibility with the Test A–G DIAG excerpts already
  in the docs. The new fields are appended.
- This logging is only called from `logGateDiagPrefix`, which only
  runs when we were already emitting a DIAG line. Zero impact on
  the detection hot path. The picker itself — `analyzeGate` at
  lines 789–882 — **is not touched.**

**Does NOT change this session:**

- `analyzeGate` picker logic.
- `localSupportFraction = 0.25`.
- `minFillRatio = 0.25`.
- `gateBandHalf = 2`.
- `maxAspectRatio = 1.2`.
- `body_part_suppression` / `approachZone`.
- `detection_spec.md`, `detection_inferences.md`, `pipeline_audit.md`.
  Per CLAUDE.md operating-mode step 2, these only move when a
  confirmed hypothesis changes the behavioral spec. We have a
  confirmed working model (frame-Y top-weighted gradient — see
  §11.4) but not a confirmed gradient *shape*, so the spec stays
  as-is until shape can be fit against expanded-DIAG data.

**Why hold the picker code now given we have a committed working
model:** because "working model is clear but the gradient shape is
undetermined" is exactly the situation CLAUDE.md's "prefer a
precise unknown over a false certainty" rule is about. Landing on
a specific gradient (linear vs exponential vs sigmoid, half-weight
Y) and then tweaking it blindly every session is how we get
`localSupportFraction` drift. Pick the shape once, against data
that shows what each candidate shape would have done on the same
frames.

### 11.6 Next physical test request

**Same lean-variation protocol as Test G**, with these changes:

1. **Front camera again** (stay consistent with Test G so the new
   data stacks on Test G data cleanly — we cannot yet stack Test
   F back-cam data with Test G front-cam data anyway).
2. **n ≥ 8 "more lean" crossings.** The failure cluster. We need a
   large enough sample within the failing cluster to design the
   fix. Fewer upright / less-lean crossings are fine — those are
   already agreeing with PF.
3. **Every crossing marked at PF's dot position**, no exceptions.
4. **User pre-labels each crossing's lean severity before the run**
   (or immediately after, while memory is fresh). Lean severity is
   the stratification variable; losing it on unmarked crossings
   halves the value of the sample.
5. **Logs will now include the expanded DIAG fields** (`tmY=`,
   `top=...`, `2nd=...`) from §11.5. When the user pastes the logs,
   I will fit candidate gradient shapes (linear, exponential,
   sigmoid) from the §11.4 working model against the expanded
   fields and pick the shape — and the half-weight Y location —
   that best tracks PF across all lean severities. The committed
   *model* is the gradient (§11.4); only the shape parameters are
   still being fit.

**No parallel PF time capture.** The user has explicitly ruled
that out as unnecessary for the Y-placement question.

**No algorithm change** until the expanded-DIAG test lands and a
gradient shape has been fit against it on ≥8 more-lean crossings.

End of section 11.
