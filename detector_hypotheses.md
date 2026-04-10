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

> ### ⚠️ Correction added 2026-04-07 — read before §11 sub-sections
>
> **Photo Finish does not display a dot.** PF's UI shows only a vertical
> line (the gate / measurement line). USER_MARK Y values throughout §11
> are the **Y coordinate of the user's finger tap on our thumbnail near
> PF's vertical line** — i.e. wherever the finger landed. They are
> **not** PF's Y choice. PF does not expose a Y coordinate anywhere in
> its UI.
>
> Therefore the following claims inside §11 are **invalid as quantitative
> claims**: every "USER_MARK Δy", "Δy = our_detY − PF_Y", "PF Y = N",
> "PF Y values", "PF Y cluster", and any rule fitting that uses
> "PF anchor Y" as a target. Treat all such numbers as finger-placement
> noise, not data.
>
> **What is still valid in §11:**
> - The qualitative finding that **PF biases the top of frame** (the
>   §11.4 "frame-Y top-weighted" working model). Confirmed by physical
>   tests, not by USER_MARK Y.
> - The leg-stripe failure mechanism on forward leans (our picker locks
>   onto the long contiguous leg run while PF anchors to the upper
>   body). Confirmed via the per-row `/all=` mask data, not via PF Y.
> - Cross-camera reproducibility (Test G front cam + Test H back cam).
> - The §11.5 instrumentation expansion (the `/tmY=`, `/top=`, `/2nd=`,
>   `/all=` fields in DETECT_DIAG).
>
> **What this changes for the picker fix:** the picker fix can no
> longer be designed to "match PF's Y value" because PF does not have
> an observable Y value. The fix must be designed against observable
> signals only: our detY, the per-row `/all=` mask data, the user's
> verbal anatomical reads of where PF's vertical line intersects the
> body, and the directional success/failure of physical scenarios
> (forward lean, backward lean, varied frame-position runs, etc.).
>
> **Forward-pointer:** see corrected §12 for the rebased framing,
> the new §12.5 finding that *PF's rule is temporal* ("PF waits for
> the upper part of the moving blob to cross the gate column before
> firing"), and the §12.7 vertical-stick test that will discriminate
> the remaining open question (relative-to-blob vs relative-to-frame).
>
> **Memory reference:** the PF-no-dot fact is also saved as the
> feedback memory `feedback_pf_no_dot_only_x_line.md` so it persists
> across sessions.

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
  per-column `topmostMaskY`, `topmostRun`, `secondRun`, and a full
  per-column run dump (every contiguous mask run, top-down). The
  existing `lng`/`tot`/`runs`/`maxGap` fields stay in place for
  backward compatibility with the Test A–G DIAG excerpts already
  in the docs. The new fields are appended in this order:
  `/tmY=` (topmost mask y), `/top=L@Y1..Y2` (topmost run),
  `/2nd=L@Y1..Y2` (second-longest run), `/all=Y1..Y2,Y3..Y4,...`
  (every run, top-down). The `/all=` field exists so that any
  candidate gradient shape — including a true run-length-weighted
  Y-centroid that needs every run, not just the top two — can be
  fit against existing logs without yet another instrumentation
  round.
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

---

## 12. Test H (2026-04-07) follow-up — corrected: Y bias confirmed, finger-tap-Y removed, NEW finding: PF's rule is temporal (waits for upper-blob mask to cross gate)

### 12.0 What this section adds + ⚠️ critical PF-no-dot correction up front

> **READ THIS BEFORE THE REST OF §12.** Earlier in this same session,
> Claude wrote a long version of §12 that built an entire analytical
> structure ("PF Y cluster mean 167 SD ≈6", "Δy = our_detY − PF_Y",
> "Test G #7 outlier at PF Y = 219", offline picker rule fitting against
> PF_Y targets) on a **false premise**: that USER_MARK Y values carry
> information about PF's Y choice. They do not.
>
> **Photo Finish does not display a dot.** PF's UI shows only a vertical
> line. The user's tap on our thumbnail "where PF marked" carries only
> X-axis information (where the line is). The Y of the tap is wherever
> the finger landed near the line — pure noise. PF does not expose a
> Y coordinate anywhere in its UI.
>
> Every "PF Y", "Δy", "PF Y cluster", and "PF anchor Y" claim from the
> prior §12 (and from the Test H section of `test_runs_our_detector.md`)
> is being walked back in this corrected §12. The same correction
> applies to §11 (banner added). The PF-no-dot fact is also saved as
> the feedback memory `feedback_pf_no_dot_only_x_line.md` for future
> sessions.
>
> The qualitative findings from the prior §12 (cross-camera replication
> of the forward-lean failure, the backward-lean discriminator
> confirming top-of-frame bias) **are still valid** and are restated
> below using observable signals only. The quantitative scaffolding is
> dropped.

§11 was based on a single front-cam run (Test G). The corrected §12
adds three things §11 didn't have:

1. **Cross-camera replication of the forward-lean failure** (back cam,
   Test H, n=5). Until Test H we did not have evidence the failure
   reproduced on the other camera.
2. **Backward-lean discriminator data** (Test H laps 5 and 6). Until
   Test H we had no crossings where the leading edge of motion through
   the gate was the lower body. The §11.4 working model makes a clean
   directional prediction for these cases — Test H is the first run
   that tested it.
3. **A NEW empirical finding from this session**, after the doc cleanup
   was triggered: **PF's rule is temporal, not just spatial.** PF
   waits for the upper part of the moving blob to cross the gate column
   before firing. This refines §11.4 from a vague "top-weighted
   gradient" into a specific testable mechanism. See §12.5 for the
   verbatim quote and the discussion.

Underlying premise of this entire section, per the user's 2026-04-07
verbal note: **PF behaves the same on front and back cam.** The rule
is a single rule. Differences between Test G (front cam) and Test H
(back cam) are differences in absolute pixel Y values driven by
camera FOV / framing, **not** PF using a different rule per camera.

### 12.1 Cross-camera replication of the forward-lean failure (qualitative, no PF Y)

**Failure signal — observable only:** on every forward-lean crossing
across both cameras, **our detY lands deep in the legs** (mid-200s
range, in the lower portion of the blob). The upper-body mask runs
visible in `/all=` for the same crossings live at frame y ≈ 120–180
(in the upper portion of the blob). Our picker is missing the upper
body by roughly 80–120 px on every lean crossing.

| run | cam | n forward-lean crossings | our detY range | upper-body mask Y range (from /all=) |
|---|---|---|---|---|
| Test G "more lean" cluster | front | 5 | ≈ 220–280 | ≈ 130–190 |
| Test H forward-lean cluster | back | 5 | ≈ 220–282 | ≈ 120–180 |

Cluster shape (range, sign, mechanism) matches across the two cameras
within noise. This is the first cross-camera reproduction of the
failure mode and **promotes the forward-lean picker bias from
"confirmed on one camera" to "confirmed across cameras"**. Combined
with the user's parity assertion this means: the failure is a
property of the picker rule, not a property of any camera-pipeline
detail (FOV, white balance, AE, mirroring, gain). Anything camera-
specific is ruled out as a primary cause.

Cited Test H crossings: laps 1, 3, 4, 7, 8 (the forward-lean
cluster). Cited Test G crossings: the "more lean" cluster from §11.

**No quantitative PF Y comparison is made here**, intentionally —
PF Y is not observable. The failure is established by our detY
being in the wrong region of the blob's mask, full stop.

### 12.2 Backward-lean discriminator confirms top-of-frame bias

**Test H lap 5** is the strongest single data point in §12. The
runner crossed with a backward lean ("stomach first"), so the
**lower body (legs/pelvis) led through the gate column in time**
while the upper body trailed. Our detY = 269 (deep in the lower
body, where our picker locked onto the long contiguous leg run).
The user verbally noted that **PF placed its vertical line on the
stomach** — i.e. PF anchored to the upper portion of the body even
though the upper body was the *temporal trailing edge*, not the
leading edge.

This is a categorical anatomical observation (a body-part read of
where PF's line intersects the body), not a pixel-Y measurement —
which makes it usable evidence under the PF-no-dot constraint.

**Test H lap 6** is a second backward-lean crossing where our
detY = 163 happened to land in the upper-body mask region by
coincidence. DETECT_DIAG analysis: c88 longest run was 81@112..192
(upper body), c89 longest was 62@74..135 (very top of frame), c90
longest was 92@186..277 (legs). The 3-column sliding average
happened to win on the c88-c89-c90 window where two of three
columns had their longest run in the upper portion. **A small
change in body geometry would flip c89 to also pick the leg
stripe**, and our picker would have dropped to the legs as in
Test H laps 1, 3, 4, 7, 8. Lap 6 is a lucky accident, not a fix.

**Read together, laps 5 and 6 confirm:** PF anchors to the upper
portion of the moving blob regardless of which body part is the
temporal leading edge. This is exactly what §11.4's "top of frame
bias" predicted for backward leans, and Test H is the first run
that tested it directly. **The §11.4 working model is now confirmed
across two independent geometries** — forward leans (Test G + Test H)
and backward leans (Test H lap 5 + lap 6).

### 12.3 Y bias is real and important — over-correction acknowledged and walked back

After discovering the PF-no-dot mistake mid-session, Claude initially
**over-corrected** by saying "Y reasoning is invalid". The user
immediately re-corrected:

> "no cause the Y value is still important since its stil important
> to know biasesing in terms of y value. since we know if we lean
> wiht the uppoer body it detects the body but if we lean iwith
> lower body it waits for upper body, so y value iss still importan
> tto note"

**Y bias is real, observable, and important.** What is *not*
observable is the precise pixel Y where PF "decided". The two are
different things. The right framing:

- **Observable Y signals (use these):** physical lean experiments,
  verbal/anatomical reads of where PF's vertical line intersects
  the body, our own detY values, the per-row `/all=` mask data,
  directional success/failure of physical scenarios.
- **Not observable (don't use these):** USER_MARK Y values as a
  proxy for PF's Y choice, "PF Y cluster" statistics, "Δy" against
  a numerical PF Y target, any rule fitting that uses PF Y as a
  fitting target.

Y bias **direction** is rock-solid (top of frame). Y bias **strength
and shape** are still being investigated — see §12.5.

### 12.4 The hard-cap proposal was rejected — recorded for future-Claude

Documenting the rejected proposal so it does not get re-proposed in
a later session. After §12.3 was understood, Claude proposed a
one-line picker fix:

```swift
let cappedY = min(longestRunMid, comp.minY + Int(0.35 * Float(comp.height)))
```

i.e. take the longest-run midpoint as today, but **cap it at ≤ 35%
from the top of the blob**. The idea was to force the picker out of
the legs into the upper-body band on lean crossings.

The user rejected this immediately:

> "this si cmletley wrong and photo finsih tests confimes this, the
> only thing photo finshi does is bias the top not completely only
> look at the top"

**Why the hard cap is wrong:** PF **biases** the top — it does not
**only look** at the top. A hard cap at 35% would force every pick
into the top fraction of the blob regardless of mask content,
ignoring the lower body entirely. PF does not do this. PF weights
the upper body more, but a long-enough or strong-enough lower-body
mass can still influence PF's behavior. The fix needs a **soft
top-weighted gradient**, not a threshold. This is exactly what
§11.4 has said all along; the hard cap was a corruption of §11.4,
not an implementation of it.

**Future-Claude:** if you find yourself about to propose
`min(longestRunMid, comp.minY + K*comp.height)` or any equivalent
hard cap, stop. Re-read this section and §12.5. Propose a soft-
weighted score per mask run instead.

### 12.5 ⭐ NEW KEY FINDING: PF's rule is temporal, not just spatial

This is the most important new content in §12 and the highest-leverage
refinement of §11.4 we have so far. The user articulated it directly:

> "actually yout mihgt be right about detection, it seems like it
> never fires on leading edge near the bittin if the frame but it
> loos at the whole blob and if the while blob is big enoghu it
> waits until oart of my hand that is more in the middle of the
> frame vs the leading part of my hand being near the bottom of
> frame . and it waits to fire until top of my hand (the part thats
> higher up) has crossed to fire"

And confirmed again on follow-up:

> "if i have a big enoguh blib that norally detects and i pass the
> leading edge being at the bottom of the frame, it never fires on
> this leading edge but waits for more of the upper part of the
> blobn to cross to fire"

**The refined working model (§12.5):** PF does not just bias the top
of frame on a single firing frame. **PF's firing decision itself is
temporal — PF waits for the upper portion of the moving mass to
reach the gate column before firing.** If the leading edge of motion
is in the lower portion of the frame, PF does **not** fire on it.
PF holds off, frame after frame, until enough of the upper portion
has crossed. The line ends up at the X where the upper portion
crossed, at the time the upper portion crossed.

**This single rule explains all four scenarios cleanly:**

1. **Forward lean:** the upper body leads through the gate in time.
   The upper portion reaches the gate column first → PF fires
   immediately on the upper body. Same fire moment as a leading-edge
   detector would give, which is why our picker also fires at
   roughly the right moment on forward leans (we just pick the wrong
   Y on that frame because we lock onto the leg run).
2. **Backward lean:** the lower body leads through the gate in time.
   The upper portion is still trailing. **PF does not fire when only
   the lower body is at the gate column.** PF waits. Eventually the
   upper portion reaches the gate → PF fires later, with the line
   on the upper body. This is the cleanest discriminator: the
   *firing moment* itself is shifted on backward leans, not just the
   Y. Test H lap 5's verbal "PF picked stomach" observation is
   exactly this rule firing.
3. **Upright no-lean:** upper and lower body reach the gate column
   at roughly the same time → PF fires "normally" on the upper body
   (which is essentially synchronous with everything else).
4. **Far / clipped runner (e.g. Test H lap 7):** the visible blob
   may only contain part of the body, but PF still tracks the upper
   portion of *the visible blob* and waits for it to reach the gate.
   PF detected lap 7 (small clipped blob, comp.minY = 150) — so
   PF's rule is not gated on an absolute "frame Y must be < N"
   threshold. PF works at any visible body size. (See §12.7 for the
   test that pins this down further.)

**Why our picker fails** under this model:

- **On forward leans:** we get the right *moment* (because the
  leading edge happens to coincide with the upper body) but the
  wrong *Y on that frame* (we pick the legs, which are the longest
  contiguous run, instead of the upper body). One-axis failure.
- **On backward leans:** we get **both** wrong. We fire too early
  (on the lower-body leading edge, before PF would fire) AND we
  pick the wrong Y (the legs again). Two-axis failure stacked.
  This second failure mode (firing too early on backward leans)
  should be visible as a **time delta between our crossing and
  PF's** if both are captured on the same physical event. We
  haven't measured that delta yet — flagging as a future check.
- **On uprights:** we usually agree because the upper-body leading
  edge dominates the longest run anyway.

**One residual ambiguity that §12.5 cannot resolve from existing
data alone:** the user's wording ("upper part of the blob") suggests
the reference is **relative to the blob**, but Claude has not
verified this, and the user has explicitly flagged that we are
**still not sure if PF uses relative-to-blob or relative-to-frame
height**. Both readings are still on the table:

- **(A) Relative-to-blob:** PF tracks the topmost portion of the
  current moving blob's mask (some top-N% region or top-weighted
  score), and waits for that portion's X to reach the gate column.
  Self-calibrating across camera mount heights and runner
  distances. The simplest rule.
- **(B) Relative-to-frame Y:** PF has a Y reference tied to the
  absolute frame (perhaps the gate line position, perhaps a fixed
  fraction of frame height, perhaps something else), and waits for
  the moving mask above that Y reference to reach the gate column.
  More complex, but possible.
- **(C) Hybrid:** PF tracks the upper portion of the blob with an
  absolute floor (e.g. "wait for the topmost mask pixel of the
  blob to reach the gate column, AND that pixel must be above
  frame Y = N"). Combines (A) and (B).

**§12.7 (vertical-stick test) is designed to discriminate (A) from
(B) and (C).** Until that test runs, §12.5's working model is "PF
waits for the upper part of the moving blob to cross the gate
column before firing", with the (A)/(B)/(C) ambiguity preserved.

**Sub-sub-ambiguity** (resolvable by a follow-up object test, not
this round): whether "upper part" means the absolute topmost mask
pixel, the top N% by row count, or a soft top-weighted score over
all rows.

### 12.6 What changes this session

**Doc-only.** No `analyzeGate` change. No parameter change. No
instrumentation change. Specifically:

- `DetectionEngine.swift` is unchanged.
- `ColStats` / `columnStats` / `logGateDiagPrefix` (the §11.5
  expansion) is unchanged — Test H confirmed the `/all=` field is
  exactly what we needed and no further instrumentation round is
  required.
- `detection_spec.md`, `detection_inferences.md`, and
  `pipeline_audit.md` do not move yet. §12.5 sharpens §11.4 from
  "top-weighted gradient" to a specific temporal mechanism, but
  the underlying §11.4 model was already committed at the
  qualitative level. The exact "how much of the upper portion needs
  to cross before firing" parameter — and whether the reference is
  relative-to-blob or relative-to-frame — is still open. The spec
  moves only when both questions are answered.

The picker fix is **deferred** until §12.7 returns and the
relative-vs-absolute question is settled. See §12.5 for why a
hard-cap fix would be wrong even with all the current data.

### 12.7 Next physical test request — vertical stick object test

**Goal:** discriminate "PF tracks the upper portion of the blob,
self-calibrating to the blob" (relative, hypothesis A in §12.5) from
"PF has an absolute Y reference somewhere in the frame coordinate
system" (B or hybrid C in §12.5).

The user requested an **object-based test** rather than body
crossings — easier to control, more reproducible, doesn't require
running.

**Equipment:** any straight rod ≥ 50 cm — broomstick, mop handle,
hockey stick, golf club, yardstick. Held vertically.

**Setup:** open Photo Finish on the iPhone, mounted the same way
the user mounts it for normal lap tests. We're testing PF's
behavior directly — no logs from our app needed for this round.
Cross-checking against our app can come later if PF's result is
ambiguous.

**The three test variations (same motion, different vertical
position):**

In all three variations, the user holds the stick **vertically**
and **walks it horizontally** through the gate column at a normal
pace. The only thing that changes is **how high the stick is held
in the frame**. Use PF's live view / thumbnail to eyeball the
stick's vertical position — exact pixel values not required.

| Test | How to hold | What it tests |
|---|---|---|
| **T1** | Stick top near the **top of the camera frame** (head/chest height) | Baseline — PF should fire normally |
| **T2** | Stick top in the **lower half of the camera frame** (waist/knee height) | The discriminator — relative model predicts fire, absolute model predicts skip |
| **T3** | Stick top in the **bottom third of the camera frame** (knee/shin height) | Stretches the discriminator further |

Repeat each test 2–3 times to filter flukes.

**What to record per test:**
- PF fired Y/N
- If yes, where the line landed on the stick (top end / middle /
  bottom end) — categorical, not pixel-Y

**What the results mean:**

| Result | Interpretation | Picker fix path |
|---|---|---|
| T1=Y, T2=Y, T3=Y | **Hypothesis A confirmed (relative-to-blob).** PF tracks the upper portion of the blob, no absolute floor. | Ship picker fix that implements the §12.5 temporal wait rule, relative-to-blob version |
| T1=Y, T2=Y, T3=N | **Hypothesis C confirmed (relative + absolute floor).** Floor lies between knee and shin height. Need a 4th test to find the exact threshold | Picker fix is more complex; needs the floor parameter |
| T1=Y, T2=N, T3=N | **Hypothesis B (strong absolute Y component).** Floor lies above knee height — relative-only model is wrong | Picker fix needs to be designed differently; further investigation required |
| T1=N | The stick is below PF's minimum-height filter | Use a longer stick |

**Confound to watch:** if T1 fails, do not interpret as "PF is
broken" — interpret as "stick is too small for PF's size filter".
We have a `heightFraction = 0.33` filter; PF likely has something
similar.

**No code changes** before this test runs and the result has been
analyzed. The current picker is unchanged.

**No backward-lean / forward-lean / body crossings in this test** —
those are saturated on the §12.5 finding. The vertical-stick test
isolates the relative-vs-absolute question that §12.5 cannot answer
from existing data.

End of section 12.


## 13. Test O (2026-04-07) follow-up — first physical hRun measurement, separation confirmed but sample too small for filter

Test O ran the post-revert build (`localSupportFraction` reverted
0.15 → 0.25, `minHeightWidthRatio` filter removed) on a mixed scenario
of hand swipes + real body crossings. n = 8 detections, user-labeled
ground truth: #1–#4 and #7 hand swipes (5 total), #5/#6/#8 real body
crossings. Full table and per-row data: `test_runs_our_detector.md`
under "Run 2026-04-07 Test O".

### 13.1 What Test O confirms

1. **`hRun` separates classes for the first time on physical data.**
   Hand swipes: hRun ∈ {7, 11, 12, 13, 35}. Real bodies: hRun ∈
   {16, 17, 18}. A threshold at `hRun ≥ 15` would correctly reject
   4/5 hand swipes and preserve 3/3 real bodies in this sample. The
   single miss is crossing #1 (`hRun = 35`) — a wide merged-motion
   blob whose horizontal extent at the detection row looks
   geometrically like a body. This is the first time the §7 / §11.4
   / §12 hRun-as-discriminator hypothesis has any physical evidence
   at all (instrumentation was added last session, no test had
   captured the field until now).

2. **The §10-predicted `localSupportFraction` revert fires on the
   intended class.** 72 distinct `[REJECT] local_support` lines in
   the Test O log, including just-barely-misses like `run=22 need=30`
   and `run=23 need=29` at frames 194–195 — exactly the
   `run < h × 0.25` mid/tall blobs the cross-tab targeted. Before
   the revert these would have fired (`0.15 × h ≈ 12–15`).

3. **The session's two parameter changes did not regress real body
   detection.** Crossings #5/#6/#8 fired correctly. Their `−19/−20`
   Δy is the pre-existing `frameBiasCap = 0.55` clamp on tall
   forward-lean blobs (`rawDetY ∈ {245, 245, 247} → detY = 176`),
   not from anything we touched this session. Unchanged since
   commit 9953368.

### 13.2 Refinement to §10 — the cross-tab over-promised on small-blob swipes

The §10 cross-tab (in `test_runs_our_detector.md` lines 2590–2776)
predicted that reverting `localSupportFraction` 0.15 → 0.25 would
reject 5/7 of the Test N elbow leakers (71%). The post-revert Test O
run shows this prediction holds **only for the Tests K–N class** of
elbow leakers (`h ∈ 116–281`), where `h × 0.25` is the binding term
of `need = max(3, h × 0.25, H × 0.08)`.

For Test O's smaller-blob swipes (`h ∈ 105–128` for crossings
#2–#4 and #7), `h × 0.25 ≈ 26–32` ≈ the `H × 0.08 = 26`
**frame-absolute floor**. The floor dominates. The lowered
`localSupportFraction` is effectively bypassed for blobs with
`h < 170`. Concrete table: `test_runs_our_detector.md` "Leak mechanism"
subsection of Test O.

**Action:** when re-reading §10, mentally substitute "71% for `h ≥ 170`
elbows; ineffective for small-blob swipes" wherever the cross-tab
claims a flat 71%. The §10 conclusion ("revert + keep fill filter is
the cleanest stack") still stands as the right *minimum* change, but
it is no longer sufficient to close the leak path on the small-blob
class — that's what brought hRun to the top of the queue.

### 13.3 Re-ranked next-action queue

Before Test O, the queue was:

- §12.7 vertical-stick test (Y-picker investigation, top priority)
- (then) hand-swipe filtering as Phase C "everything else"

After Test O, the queue is:

1. **PF parallel capture on thin-arm swipes vs body crossings (Test P,
   §13.4 below).** This is the new top priority because it directly
   answers whether the freshly-measured hRun signal is fidelity or
   divergence from PF, and it costs one physical test session.
2. **§12.7 vertical-stick test.** Still pending. Demoted one notch
   only because Test P costs the same and unlocks an in-progress
   change path. After Test P resolves the hRun question, §12.7 is
   back at the top of the queue.
3. **Anything else** — body-part suppression rewrite (§2.11), morphology
   pre-components, arrival-into-gate (§3.2). Same priority as before.

### 13.4 New top open question

**Q:** Does PF fire on thin-arm swipes of the kind that produced
Test O crossings #2/#3/#4/#7?

- **If yes** → hRun is divergence from PF. Do not add the filter.
  Per `feedback_replicate_not_improve_pf.md`, the success metric is
  matching PF, not matching anatomy. Move back to §12.7 vertical-stick
  test.
- **If no** → both (a) our logs (Tests O + P) and (b) PF ground-truth
  agree that thin-arm swipes are false positives. Then `hRun ≥ 15`
  is justified for code change, in a separate focused plan. The
  threshold choice should be revisited with the combined Tests O + P
  sample.

This is the question Test P (§13.5 below) is designed to settle.

### 13.5 Next physical test request — Test P (PF parallel capture, hand swipes vs bodies)

**Goal:** decide whether the `hRun ≥ 15` filter is fidelity to PF or
divergence from PF.

**Setup:** mount our app on the test phone (back camera as configured).
Run **Photo Finish** on a **second phone** placed alongside the test
phone, framing the same gate line. Both apps recording simultaneously.
On every crossing, tap USER_MARK on our app at the moment PF's vertical
line appears, so we can correlate per-crossing.

**Three labeled blocks (do them in order, do not interleave):**

1. **10 thin-arm swipes across the gate, body out of frame.** Reach
   across the gate column with just the forearm. Vary speed
   (fast / medium) and starting side. Goal: see whether PF triggers
   on these at all. **Mark each one** with USER_MARK regardless of
   whether PF fires, so we can match PF's silence to our detector's
   trigger.

2. **6 upright body crossings at walking pace, no lean.** Goal: confirm
   the `hRun ≥ ~16–18` lower bound for real bodies as a second
   datapoint to Test O.

3. **4 forward-lean body crossings at running pace.** Goal: confirm
   `hRun` is also `≥ 16` on **leans**. Critical because the whole
   reason `minHeightWidthRatio` was removed in this session is that
   it clipped 3 of 4 forward-lean bodies in the §10 cross-tab. An
   `hRun` filter must not regress that.

**Total:** 20 crossings.

**Per-block reporting back:** for each crossing, paste the matched
`[DETECT]` line from our app *and* a verbal note "PF fired Y/N" so
the cross-tab below can be filled in.

**Decision matrix:**

| Block 1 PF fire rate | Block 2 hRun | Block 3 hRun | Verdict |
|---------------------|--------------|--------------|---------|
| ≥ 50% | any | any | PF also fires on thin arms → **hRun is divergence; do not add the filter**. Pivot back to §12.7. |
| ≤ 20% | all ≥ 15 | all ≥ 15 | PF rejects thin arms; bodies stay above hRun threshold → **hRun ≥ 15 justified for code change**. Open follow-up plan. |
| ≤ 20% | any ≥ 15 | **any < 15** | hRun threshold would clip a real lean → **filter is unsafe**. Either lower the threshold and re-decide, or pivot back to §12.7. |
| 20–50% | any | any | Ambiguous. Run more reps before deciding. |

**No code changes** between Test O and Test P. Documentation-only,
per CLAUDE.md operating-mode §4.

### 13.6 Things we should NOT do before Test P

1. **Do not add `hRun ≥ 15` to `DetectionEngine.swift`.** Tempting
   because the Test O split is clean. n = 8, no PF parallel data.
   Operating-mode bar is not met.
2. **Do not raise `heightFraction` 0.33 → 0.40** to catch Test O's
   small-blob class through the size filter. Same reason. Also it
   would directly conflict with the spec value of ~0.30 and would
   need its own justification ladder.
3. **Do not re-introduce `minHeightWidthRatio`** in any form. The §10
   cross-tab showed it clips 3 of 4 forward-lean bodies. This was
   removed for a reason that has not changed.
4. **Do not touch `frameBiasCap = 0.55`.** The `−20` Δy on Test O
   bodies is the clamp doing what it was designed to do. The clamp's
   correctness is the §12.7 vertical-stick test's job to settle, not
   Test P's.

End of section 13.


## 14. Test P (2026-04-07) follow-up — hRun hypothesis refuted, picker bug re-centered

Test P ran the decision test from §13.5: 18 detections (17 usable,
#18 excluded per user), parallel Photo Finish capture, user-labeled
ground truth. Full table and per-row data: `test_runs_our_detector.md`
under "Run 2026-04-07 Test P".

### 14.1 Sample composition (user-labeled)

- **Block 1 — elbow test** (body out of frame, vertical elbow-to-fingers blob, PF silent, we fired): #1–#9, n=9
- **Block 2 — regular walking** (PF fired, we fired): #10, #11, #12, #13, n=4 (#13 placed correctly per user)
- **Block 3 — lean body** (PF fired, we fired): #14 regular lean, #15 lean with arms out, #16 uncertain, #17 arm backwards chest first, n=4

The "circular motion thin hand swipes" the user did at the start of
the session were rejected by the existing filters before reaching
`[DETECT]` — visible in the run's 137 `local_support`, 130 `fill_ratio`,
and 41 `aspect_ratio` rejects.

### 14.2 hRun hypothesis is refuted

Per-class hRun distributions:

| class | n | hRun values (sorted) | range |
|-------|---|---------------------|-------|
| elbow (block 1, PF silent) | 9 | 6, 8, 9, 11, 12, 14, 15, 16, 17 | 6–17 |
| real bodies (blocks 2+3, PF fired) | 8 | 11, 11, 13, 14, 14, 14, 15, 19 | 11–19 |

**Complete overlap.** The Test O model ("hands ≤ 13, bodies ≥ 16")
does not survive contact with a bigger sample.

`hRun ≥ 15` (the §13.4 candidate threshold) would reject **6/9
elbows and 6/8 bodies**. The filter rejects more real bodies than
false positives. No threshold in the observed range cleanly separates
the classes; `hRun ≥ 10` is the only setting that keeps all real
bodies, and it only catches 3/9 elbows.

**Decision:** reject `hRun ≥ 15` as a filter. Per §13.5 decision
matrix row 3 ("PF rejects thin arms but any lean has `hRun < 15` →
filter is unsafe"). Do not add it to `DetectionEngine.swift`.

Operating-mode lesson recorded: **n = 8 is not enough to commit a
filter threshold.** The Test O split was real for that sample but
not reproducible. The CLAUDE.md §4 rule ("documentation-only is the
default, code change is the exception") prevented the mistake — if
we had coded the hRun filter after Test O we would have regressed
lean detection on 6/8 bodies in Test P. Keep this lesson cited
whenever a small-sample signal tempts a premature code change.

### 14.3 Why hRun collapsed — the picker is landing on legs

The Test O hRun signal was not wrong; it was correct *given the
picker's row choice*. The picker's row choice is the bug. Computing
where `rawDetY` landed inside each body's y-range in Test P
(pre-clamp, to see what the picker actually picked):

| # | blob y range (h) | rawDetY | position in blob |
|---|------------------|---------|------------------|
| 10 | 61..317 (h=257) | 271 | 82 % down — shin |
| 11 | 100..234 (h=135) | 138 | 28 % down — upper torso |
| 12 | 67..207 (h=141) | 163 | 68 % down — lower torso |
| 13 | 65..315 (h=251) | 268 | 81 % down — shin |
| 14 | 143..319 (h=177) | 276 | 75 % down — thigh/shin |
| 15 | 30..319 (h=290) | 253 | 77 % down — knee/shin |
| 16 | 131..319 (h=189) | 272 | 75 % down — thigh |
| 17 | 168..315 (h=148) | 287 | 80 % down — shin |

**7 of 8 bodies have the picker landing in the lower 68–82 % of the
blob.** Only #11 lands in the upper torso (28 %). This is the §11.4
/ §12 picker bug, unchanged. The `frameBiasCap = 0.55` clamp hides
it on the output (all clamp cases come out as `detY = 176`) but the
raw picker rows are still at shin height.

At shin height, the horizontal mask width is **one leg plus maybe a
motion stripe = 11–14 px**, which is exactly the elbow hRun range.
Legs and elbows look the same at the scan row because legs and
elbows are both single-limb-width horizontal slices of a moving
body. **Fixing the picker to land at the torso (where torso hRun ≈
30–60 px) would make the hRun separation real — as the §7 / Test O
hypothesis originally predicted.**

This is a significant unification: the hand-swipe false-positive
problem and the lean Δy bug are the **same bug** seen from two
different scenarios. The picker is not anchored to an upper-blob
reference, so:

- For real bodies, the picker lands in the legs (→ Δy ≈ −20 after
  the clamp, and hRun ≈ 11–14).
- For elbows, there is no torso to ignore — the picker lands on
  whatever stripe has the longest vertical run, which is often the
  forearm itself. hRun ≈ 6–17.

### 14.4 Re-ranked next-action queue (post Test P)

1. **§12.7 vertical-stick test.** Was demoted one notch in §13.3; now
   promoted back to top. Test P provides fresh motivation — every
   Block 2 walking body has the picker landing in its legs, so the
   picker fix is the single change with the highest expected impact
   on BOTH active failure modes (hand-swipe false positives + lean
   Δy bias). Run it exactly as written in §12.7.
2. **Do nothing else on the detector until §12.7 results are in.**
   Specifically: do not add any new filter, do not touch
   `heightFraction`, do not touch `frameBiasCap`, do not lower
   `localSupportFraction`, do not reintroduce `minHeightWidthRatio`.
3. **After §12.7:** pick the §12.5 hypothesis (A / B / C) that the
   vertical stick test confirms, implement the corresponding picker
   fix, then re-run Test P's block 1 to see whether the fix alone
   closes the hand-swipe false-positive problem — the unification
   prediction in §14.3 says it should.

### 14.5 Leads observed but not actionable yet

- **Blob `h` separates the classes in Test P** (elbow max 142,
  body min 135). At `heightFraction ≥ 0.44` (`h ≥ 141`) every elbow
  would be rejected. **Cost:** also rejects #11 and #12, both
  user-labeled "regular walking" bodies whose blobs are
  mid-frame-only (y=100..234, y=67..207), probably partial-body
  framing. This is a 33 % tightening on top of a parameter already
  stricter than the spec. **Do not adopt.** If the picker fix lands
  and this test is repeated, revisit.
- **Blob `y` range bottom = 319 for every clamp-firing body** but
  for #11/#12 the bottom is 234/207 (well inside the frame). Could
  turn into a "requires contact with frame bottom" heuristic — but
  that's a fragile framing constraint and also gets resolved
  organically once the picker lands in the torso region rather than
  the legs.
- **`maxGap` / `runs` / `tot` fragmentation fields were NOT logged
  on Test P** the same way they were on Tests G/H, because Test P
  emitted `[DETECT]` only for the 18 crossings, not `[DETECT_DIAG]`
  on a per-candidate basis. If the next test is body-oriented (not
  §12.7), enable `DETECT_DIAG` per-detection so we can finally get
  fragmentation data for elbows and regular walking side-by-side.

### 14.6 Things Test P definitively closed

- **The §13 hRun-filter plan.** Closed, refuted.
- **The §10 cross-tab's small-blob caveat.** Also closed — not only
  did the revert not catch small blobs, but no single already-logged
  feature catches them without collateral. The discriminator the
  cross-tab was looking for does not exist at the single-feature level.
- **"The hand-swipe problem is orthogonal to the lean picker bug."**
  Closed. They are the same bug. Test P is the evidence.

### 14.7 Things Test P did NOT resolve

- **Whether the §12.5 temporal-wait rule is relative-to-blob or
  relative-to-frame.** §12.7 is still required.
- **Whether PF's picker has a hard upper floor or a soft top-weighted
  gradient.** Same.
- **The #11/#12 "partial body" framing** — what was the user actually
  doing for these two crossings? They fired with the picker *above*
  the leg bias for #11 (28 % down), which is unique in the sample.
  Needs a targeted repeat if it turns out partial-body framing is a
  common case.

End of section 14.

---

## §15 Arm-spike detection — implementation + Test R results (2026-04-08)

### §15.1 What was implemented

Added `adjustForArmSpike` to `DetectionEngine.swift` (lines 953-1044): per-row hRun profiling at the gate column with median-based spike detection (threshold = median × 1.5). If the picker lands on a spike row, shifts detY to the midpoint of the longest contiguous non-spike band. Also added xMin/xMax per row to HRUN_PROFILE logging so the blob's horizontal position is visible.

Pipeline order: picker → spike correction → frameBiasCap clamp → interpolation.

### §15.2 Test R findings (front camera, 11 crossings)

**Normal walks (#1-5):** Natural arm swing during walking creates bigger spikes than intentional arm-lifting. Laps 3 and 5 showed 39-41 px spikes on 15 px median bodies — the arm swings forward and fuses with the torso at the gate. The picker avoided the spike rows naturally; no correction fired.

**Arm-lifted crossings (#6-10):** Raising the arm overhead does NOT fuse it with the torso blob — the profiles are thin (7-8 px median), blobs are small. The arm stays separate in connected components. However, detection fires late because the arm inflates the bounding box, dropping fill_ratio below 0.20 for multiple frames (lap 9: 18 frames of fill_ratio rejects at 0.08-0.19).

**PF comparison:** PF fires at consistent X positions on normal walks (Δx ≤ 15 from our gate) but is highly inconsistent on arm-lifted crossings (userX ranges 62-135). PF also appears to struggle with this pose.

### §15.3 What we know now

- The spike detection mechanism works (flags spike rows, profiles show clear arm signatures) but has never needed to fire because the picker avoids spike rows naturally.
- The real problem with arm-extended crossings may not be the picker landing on the arm — it may be the fill_ratio prefilter rejecting the inflated bbox, causing late detection.
- Arm overhead ≠ arm forward. Overhead arms don't fuse with the body; forward-swinging arms do (natural walk arm swing creates bigger fused spikes).
- PF is also inconsistent on arm crossings, suggesting this is an inherently difficult pose for geometry-based detectors.

### §15.4 Open questions

- Should fill_ratio be computed on a tighter bbox excluding spike rows? Needs more testing — lowering minFillRatio globally would re-introduce hand-swipe false positives.
- Is the spike detection needed at all if the picker naturally avoids spike rows? More crossing data needed to find a case where it doesn't.
- Forward arm extension (arm leads through gate) has not been tested with the new profiling. This is the scenario most likely to put the picker ON a spike row.

---

## §15.5 Test S results — tightFill diagnostic confirms arm inflation (2026-04-07)

### What Test S showed

6 arm-raised walk crossings attempted (back-and-forth), 5 detected, 1 completely missed.

**tightFill hypothesis confirmed:** On the 5 frames where `diagTightFill` successfully computed, values were 0.44-0.94 (3-5× higher than raw fillRatio of 0.13-0.19). The arm stretches the bounding box without filling it; trimming spike rows from the effective height would bring fill well above the 0.20 threshold.

**Coverage problem:** tightFill returned -1 on most frames. The function starts from the blob's geometric center (`(minY+maxY)/2`), which may not have a mask pixel at the gate column on fragmented blobs. To use tightFill as a real filter, it needs to start from a row known to intersect the gate (e.g. use the gate-run analysis that already exists in `analyzeGate`).

**Missed crossing:** One L→R crossing (frames 535-567) never fired despite buildup=6. Fill and local_support alternated failures — the blob never satisfied all checks simultaneously. This is the worst outcome: a real crossing that our detector completely drops.

**PF also inconsistent:** Δx ranged from -35 to +50 on arm-raised walks. Both detectors struggle with this pose, consistent with Test R.

### §15.6 Assessment: arm-raised investigation status

Two tests (R and S) now show the same pattern:
1. Arm-raised walks cause fill_ratio to drop below 0.20 due to bounding-box inflation
2. tightFill (spike-row-trimmed height) would fix this — confirmed by diagnostic data
3. PF is equally inconsistent on arm-raised poses (Δx ±50)
4. Spike detection (picker correction) has never fired — picker avoids spike rows naturally

**Decision point:** Since PF itself struggles with arm-raised crossings, this may not be the right scenario to optimize for under the "replicate PF" principle. The arm-raised fill problem is real and fixable, but PF doesn't solve it either.

**Recommendation:** Park arm-raised as a known limitation shared with PF. Move investigation to the priority issues: (1) forward-lean failure mode, (2) leg-in-front-of-body — these are scenarios where PF succeeds and we need to match it.

---

## §15.7 Test T results — fill_rescue active (2026-04-08)

### What Test T showed

9 real crossings (excluding lap 4 "ignore"), all detected. FILL_RESCUE activated on 3 crossings (laps 2, 6, 9) that would have been fill_ratio rejects without the fix. This is a clear improvement over Test S (1 miss in 6).

### Key finding: frame-absolute floor dominates, not effectiveHeight

The effectiveHeight threading into analyzeGate had minimal impact. In most rescue cases, the local_support need is 25 (from H×0.08 = 320×0.08 floor), not from trimmedH×0.25. For trimmedH values of 7-23, trimmedH×0.25 = 1-5, well below the floor. The effectiveHeight fix only matters when trimmedH > 100, which never occurred.

**The real fix is the tightFill fill_ratio bypass** — it lets arm-inflated blobs past the fill check. The effectiveHeight change is harmless but largely inert.

### Remaining problems

1. **Lap 7 (buildup=12):** Body crossed while detector was still building up. FILL_RESCUE fired at frame 799 (trimmedH=11) but gate run was only 12 vs need=25. The blob that eventually detected (frame 807) was the arm/hand behind the body, not the torso crossing. This is a timing failure, not a filter failure.

2. **High buildup on several laps:** Laps 7(12), 8(7), 9(9). The fill_rescue helps blobs that would have been missed entirely, but arm-raised crossings still require multiple frames before all checks align. This is consistent with PF also being inconsistent on arm-raised poses (Δx up to +48).

3. **tightFill values > 1.0:** Common when trimmedH is small. Not geometrically meaningful but passes the threshold correctly. Could add a cap at 1.0 for cleaner logging but functionally irrelevant.

### Assessment

The fill_rescue fix is a net positive: 9/9 detected vs 5/6 in Test S. The fix primarily helps through the tightFill fill_ratio bypass. The effectiveHeight component is largely inert due to the frame-absolute floor dominating.

**Next:** Need to test normal walks and hand swipes to verify no regressions before keeping this code.

---

## §16 Test U (2026-04-10) — fill_rescue regression check + hand-in-front data

### §16.1 What Test U tested

Front camera, 9 crossings: laps 1–6 normal walks, laps 7–9 hand held in front of body
(chest/stomach height) while crossing. Goal: satisfy the §15.7 "test normal walks to
verify no regressions" gate before considering fill_rescue final.

### §16.2 What Test U showed

**All 9 detected.** The §15.7 regression gate is satisfied for normal walks. No false
positives appeared between crossings.

**fill_rescue contributing on hand-in-front crossings.** Eight FILL_RESCUE activations
across the buildup frames for laps 2/7/8/9. tightFill values of 1.0–4.0 on frames where
raw fill was 0.13–0.19. The mechanism is working as designed.

**hRun distribution further confirms no-filter decision.** Normal walks: hRun = 6–75.
Hand-in-front: hRun = 11–17. Classes overlap completely. Test P already closed this
question; Test U is additional confirmation.

**Δy bias unchanged.** Tall blobs (h≥243px) land detY within 1px of user tap. Shorter
or wider blobs show Δy = −14 to −29 (picker too low). This is the §12.5 leg-stripe
picker failure mode, unchanged since it was characterized. No new information.

**PF Δx on hand-in-front is tight (−12 to +3).** Significantly tighter than arm-raised-
overhead (±50 in Tests R/S). Hand-in-front does not disrupt PF's gate timing the way
an arm overhead does.

**Lap 2 anomaly: 180×153 full-width blob, hRun=75.** User called it a normal crossing.
The full-frame width and high hRun suggest a leaned or close-proximity crossing. Picker
landed at 43% down from blob top (detY=121). No regression from this — the detector
handled it correctly. Worth noting because it's the only data point where our picker
landed in the upper portion of a wide blob without the characteristic Δy=−14..−29.

### §16.3 What Test U did NOT resolve

- **Hand swipes (flat horizontal swipes) as false positives** — this is the remaining
  regression test that §15.7 originally flagged. Lower priority because (a) no hand
  swipe false positives have appeared in recent tests and (b) tightFill rescue only
  activates when fill <0.20, and hand swipes passed fill≥0.25 in earlier tests.
  Still an open check but not blocking.
- **The §12.5 picker bias** — Δy = −14 to −29 on most crossings remains unaddressed.
  This is expected; the fix is gated on §12.7.

### §16.4 Re-ranked next-action queue (post Test U)

1. **§12.7 vertical-stick test.** Unchanged. Still the top priority. Test U provides no
   new evidence bearing on the relative-vs-absolute question. The picker fix cannot be
   designed until §12.7 settles hypothesis A/B/C.
2. **Hand-swipe false-positive regression on fill_rescue.** Lower priority. No urgency
   given zero hand-swipe false positives in recent sessions. Can be folded into the
   next general-purpose test session if needed.
3. **Everything else** — unchanged from §14.4.

**fill_rescue is considered validated for normal walks and hand-in-front crossings.
No code changes needed from this test.**

**Next physical test: §12.7 vertical-stick test.** See §12.7 for the full protocol.
Equipment: any rod ≥50cm. PF only — our app not needed. Three variations (stick top
at head/chest height, waist/knee height, knee/shin height), 2–3 reps each. Record:
PF fired Y/N, and where the line landed on the stick (top/middle/bottom).

