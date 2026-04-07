# Our Detector — Test Runs

Raw run logs from physical testing of **our own** reverse-engineered detector
(this is distinct from `raw_test_results.md`, which captures observations of
the original Photo Finish app). Each run section pairs the detector's exact
algorithm/parameter state at the time of the run with the observed results,
so we can relate old findings to new ones as the pipeline evolves.

---

## Run 2026-04-06 Test A — "early on lower leg" regression

**Device / setup:** iPhone, back camera, tripod, gate column = center (x=90 in
process coords). Front camera swap logged at session start but crossings used
back camera.

**Build:** commit `307b689` (_Fix interpolation direction, add closest-frame
thumbnail, show interp overlay_) plus same-session instrumentation additions
before this run:
- Removed per-30-frames `[ENGINE] frame=X exp=Xms ISO=X` log in
  `CameraManager.swift` (was stealing the processing queue)
- Added `[GATE_DIAG]` close-miss diagnostic in `DetectionEngine.swift` for
  rejections where `overallBestAvg ≥ 0.7 * need` (near-miss local_support)
- Added `[DETECT_DIAG]` diagnostic printed immediately after each `[DETECT]`
- Introduced `ColStats` struct, `columnStats(gx:comp:)` helper, and
  `logGateDiag` / `logGateDiagPrefix` printers

### Detector algorithm snapshot (what was actually running)

Pipeline stages in order, for the exact build that produced the results below:

1. **Y-plane extraction** into a 180×320 portrait process buffer
   (`extractGray`, transpose when source is landscape). Scale factors
   computed from buffer dims: for 1280×720 source → `scaleX = scaleY = 4`.
2. **Frame differencing** against previous frame's Y buffer, binary mask where
   `|Δ| ≥ 15` (`diffThreshold = 15`).
3. **Warmup skip:** first 10 frames after start ignored (`warmupFrames = 10`).
4. **Cooldown:** 0.5 s real-frame-time gap enforced between successful
   detections (not crossing-time gap, so frame drops cannot reopen it).
5. **8-way connected components** with two-pass union-find on the binary mask.
6. **Size prefilters** per component:
   - `height ≥ 0.33 × 320 = 105 px` (`heightFraction = 0.33`)
   - `width  ≥ 0.08 × 180 =  14 px` (`widthFraction  = 0.08`)
7. **Fill ratio filter:** `area / (width × height) ≥ 0.25`
   (`minFillRatio = 0.25`). Rejects sparse hand swipes.
8. **Aspect-ratio filter:** `width > 1.2 × height` rejected
   (`maxAspectRatio = 1.2`). Rejects wide-flat blobs like horizontal legs or
   hand swipes.
9. **Gate-band intersection:** component must straddle the gate band
   `x ∈ [gateColumn − 2, gateColumn + 2]` = `[88, 92]`
   (`gateBandHalf = 2`).
10. **Per-column longest vertical run** computed for each gate-band column:
    iterate `y ∈ [comp.minY, comp.maxY]`, track the longest consecutive
    run of set mask pixels in that column. Also track the midpoint Y of
    that run.
11. **Sliding-window averaging** with window width `sliceWidth = 3` columns
    across the 5 gate-band columns. The per-window score is the **average**
    of per-column longest runs (not the minimum), so one weak column does
    not kill the window. This models a graded score and matches Photo
    Finish's smooth leading-edge behavior on bottles.
12. **Leading-edge scan order:** windows are visited starting from the
    leading-edge side (high X if moving L→R, low X if moving R→L). The
    **first** window that satisfies `avgRun ≥ need` is returned — no
    "pick the best" pass. If none qualify, the overall-best-window is
    kept for diagnostics only.
13. **Local-support threshold:**
    `need = max(3, 0.25 × comp.height, 0.08 × 320 ≈ 25)`
    — i.e. the bigger of 25% of the blob's height or a hard frame floor
    of ~25 px. For a 258-px-tall blob this is `max(3, 64, 25) = 64`.
14. **Body-part suppression:** for every larger size-qualified component
    NOT at the gate, if its leading edge is within `0.20 × 180 = 36 px`
    of the gate, the current detection is suppressed and the detector
    waits for the larger blob. This is the "elbow in front of torso"
    guard.
15. **Position-based interpolation:** at the winning detection row
    `detRow = detY`, scan the mask horizontally left and right of the
    gate column until the run ends. Use the resulting `dBefore` and
    `dAfter` to compute `fraction = dBefore / (dBefore + dAfter)` and
    interpolate between frame N-1 and N timestamps.
16. **Low-light exposure correction:** add `0.75 × exposureDuration` when
    the exposure exceeds 2 ms, per the Photo Finish paper's fudge factor.
17. **Direction determination:** component centroid X vs gate column →
    `movingLeftToRight`.
18. **Thumbnail frame choice** (in `CameraManager`): use previous frame's
    YUV planes if `fraction < 0.5`, else current frame. This is the
    closest-frame pick.

### Parameter values (exact)

| name | value |
|---|---|
| `processWidth × processHeight` | 180 × 320 |
| `diffThreshold` | 15 |
| `heightFraction` | 0.33 |
| `widthFraction` | 0.08 |
| `localSupportFraction` | 0.25 |
| `minGateHeightFraction` | 0.08 |
| `minFillRatio` | 0.25 |
| `maxAspectRatio` | 1.2 |
| `sliceWidth` (gate window) | 3 |
| `gateBandHalf` | 2 |
| `cooldown` | 0.5 s |
| `warmupFrames` | 10 |
| `body_part_suppression approachZone` | 0.20 × processWidth = 36 px |
| `exposure correction factor` | 0.75 × exposureDuration (if > 2 ms) |
| capture preset | `.hd1280x720` (scale = 4) |
| pixel format | `420YpCbCrVideoRange` (Y plane video-range [16–235]) |
| frame rate | locked 30 fps |
| stabilization | off |
| Center Stage | off |

### Run: 21 crossings

Excerpted from the session log. `need` is computed from blob height as
`max(3, ⌈0.25 × h⌉, 25)` for rows where only the DETECT line was visible.

| # | time (s) | blob (WxH) | detY | run/need | dir | interp dB/dA | user verdict |
|---|----------|------------|------|----------|-----|--------------|--------------|
| 1 | 0.896 | 130×145 | 234 | 37/36 | L→R | 0 / 0 | good |
| 2 | — | — | — | — | — | — | (scrollback truncated — reconstruct from user notes) |
| 3 | — | — | — | — | — | — | early on lower leg |
| 4 | — | — | — | — | — | — | early on lower leg (leg not fully vertical) |
| 5 | — | — | — | — | — | — | on lower leg → too early |
| 6 | — | — | — | — | — | — | too late, full body, no leg showing |
| 7 | — | — | — | — | — | — | too late |
| 8 | — | — | — | — | — | — | on lower leg |
| 9 | — | — | — | — | — | — | lower leg → too early |
| 10 | — | — | — | — | — | — | good (maybe slightly late, not quite leg) |
| 11 | — | — | — | — | — | — | (scrollback truncated) |
| 12 | — | — | — | — | — | — | (scrollback truncated) |
| 13 | — | — | — | — | — | — | lower leg |
| 14 | — | — | — | — | — | — | lower leg or hand — lower leg not fully vertical, same issue |
| 15 | — | — | — | — | — | — | lower leg |
| 16 | — | — | — | — | — | — | (scrollback truncated) |
| 17 | — | — | — | — | — | — | lower leg ish, same issue, way early |
| 18 | — | — | — | — | — | — | early again |
| 19 | — | — | — | — | — | — | early, lower leg |
| 20 | 74.569 | 125×261 | 283 | 72/65 | R→L | 7 / 25 | lower leg |
| 21 | 77.189 | 127×258 | 269 | 100/64 | L→R | 38 / 10 | (no verdict captured) |

Rough tally (from visible feedback): ~13 early on lower leg, ~2 too late on
torso, ~4 good, remainder not captured. The dominant failure mode has
**flipped** — previously it was "misses on thin blobs", now it is "early
fires on lower leg".

### DETECT_DIAG samples (winning-blob per-column stats)

From the visible log excerpts:

```
# Crossing 1 (detY=234, blob 130x145, run=37)
cols=[c88:lng=36/tot=91/runs=10/maxGap=29
      c89:lng=33/tot=83/runs=10/maxGap=30
      c90:lng=39/tot=87/runs=10/maxGap=?
      c91:lng=?/tot=86/runs=7/maxGap=32
      c92:lng=31/tot=78/runs=10/maxGap=33]

# Crossing 20 (detY=283, blob 125x261, run=72)
cols=[c88:lng=72/tot=106/runs=7/maxGap=64
      c89:lng=73/tot=103/runs=8/maxGap=61
      c90:lng=73/tot=108/runs=10/maxGap=?
      c91:lng=?/tot=114/runs=12/maxGap=39
      c92:lng=67/tot=116/runs=13/maxGap=54]

# Crossing 21 (detY=269, blob 127x258, run=100)
cols=[c88:lng=102/tot=121/runs=6/maxGap=42
      c89:lng=101/tot=121/runs=6/maxGap=?
      c90:lng=?/tot=120/runs=7/maxGap=37
      c91:lng=100/tot=120/runs=6/maxGap=44
      c92:lng=101/tot=123/runs=5/maxGap=43]

# A GATE_DIAG close-miss on a frame-filling noise blob (later in the session)
blob=180x320 need=80 avg=62
cols=[c88:lng=65/tot=253/runs=31/maxGap=?
      c89:lng=61/tot=261/runs=31/maxGap=12
      c90:lng=60/tot=253/runs=31/maxGap=17
      c91:lng=43/tot=247/runs=30/maxGap=?
      c92:lng=?/tot=244/runs=32/maxGap=35]
```

### Aggregate observations

- **detY does not separate leg from torso.** Good detections at detY=234, 280,
  280 overlap with "lower leg" detections at detY=244..286. A visual marker
  on the thumbnail is required to disambiguate.
- **Mask is gappy, not sparse.** Every logged column has `tot >> lng` and high
  `maxGap` (29..64 on real crossings, up to 17..39 on noise). The detector is
  finding the longest run inside one subsegment of the blob, not across the
  whole torso. This means "longest run wins" is being driven by wherever the
  mask is locally densest — and locally densest can be the shin if the shin
  is fully vertical at the gate but the torso above it has gappy motion.
- **Body-part suppression did not fire** for the early-leg cases. That is the
  spec's whole job against exactly this failure mode (leg ahead of torso),
  which suggests the leg is not coming through as a **separate** component
  — it is part of the same connected blob as the torso, and the sliding
  window just happens to score highest at the shin.
- **Close-miss GATE_DIAG shows `blob=180x320`** — a whole-frame noise
  component is being produced, presumably during movement or lighting
  change. `avg=62 need=80` means it was ~77% of threshold, which is why
  it showed up (≥70% close-miss filter). It did not fire, so this is not
  a bug, just noise to be aware of.

### Gaps in this data that the next instrumentation pass fixes

1. **Longest-run Y-range not logged.** I have `lng=63` but not the Y interval
   that run occupies. I need `lng=63@255..317` to tell whether the winning
   subsegment is on the shin, knee, or torso.
2. **Winning sliding-window index not logged.** `sliceWidth=3` means 3 of the
   5 gate-band columns won. I cannot tell whether the leading-edge side
   columns or the trailing-edge side columns drove the decision.
3. **Frame number missing on GATE_DIAG and REJECT lines.** DETECT has
   `frame=N`, GATE_DIAG does not. Correlation across frame drops is
   ambiguous.
4. **No visual pixel marker on lap thumbnails.** The user has to describe
   "this one looked like a leg" in words. A dot at (gateColumn, detY) on
   each thumbnail would make the failure mode immediately visible.

All four are addressed in the same session before the next physical test.

---

## Run 2026-04-06 Test B — hand swipes (thumb-reject sanity)

**Device / setup:** iPhone, **front camera** (swapped at session start —
back camera was default but `[CAMERA] switched to front` fired before
detection started), tripod, 30 fps locked, `hd1280x720` preset,
stabilization off, Center Stage off, process buffer 180×320, gate column =
center (x=90), `scaleX=scaleY=4` (`[INIT] buffer=1280x720 bpr=1280
landscape=true process=180x320 scaleX=4 scaleY=4`).

**Build:** commit `307b689` + same-session instrumentation landed before
this run (the four Test-A gap fixes are now live):

- Longest-run Y-range (`lng=N@sY..eY`) on every DETECT_DIAG / GATE_DIAG
  column entry.
- Frame-number prefix (`frame=N`) on every `[GATE_DIAG]` and `[REJECT]`
  line.
- Winning 3-column window marker (`>cN`) on DETECT_DIAG / GATE_DIAG, so
  the three gate-band columns that drove the detection are visible at a
  glance.
- Yellow detector dot rendered on lap-card + fullscreen thumbnails at
  `(gateColumn, detY)`.
- Tap-to-mark ground truth on fullscreen: taps produce a green dot and
  emit `[USER_MARK] #N detY=… userY=… Δy=… userX=… time=…` to the log.
- "Copy" button in the lap list header that dumps the current run as a
  markdown table to the pasteboard.
- Fullscreen overlay switched from captured `LapRecord` to id-based
  lookup against `camera.crossings`, so the green dot updates live when
  a tap mutates the record.

**Purpose of the run:** sanity-check the instrumentation on the new
tap-to-mark loop and verify thumb-reject behavior. User swiped their hand
through the gate (thumb sticking out) the way the original Photo Finish
app was probed, to see whether the detector would correctly ignore the
thumb.

### Detector algorithm state

**Unchanged from Test A.** Same 18-stage pipeline, same parameter values —
see the Test A "Detector algorithm snapshot" and "Parameter values (exact)"
sections above. No algorithm tweaks between Test A and Test B; all
differences in this run come from instrumentation + the test subject
(hand swipe vs running body).

### Run: 13 crossings

Extracted from the full log paste. Blob height `h` is the component height
in process pixels. `need = max(3, ⌈0.25 × h⌉, 25)`.

| # | frame | time (s) | blob (W×H) | detY | win | winning cols (key) | dir | interp dB/dA | USER_MARK Δy | thumb-reject evidence |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 33 | 1.078 | 167×223 | 141 | c90>c91>c92 | c90:98..182 c91:101..182 c92:101..182 | L→R | 26/19 | — | no thumb context |
| 2 | 35 | 1.225 | 180×220 | 206 | c90>c91>c92 | c90:121..291 c91:120..294 c92:119..294 | L→R | 20/80 | `#2 userY=169 Δy=-37` | — |
| 3 | 60 | 3.340 | 158×221 | 138 | c90>c91>c92 | c90:101..175 c91:105..175 c92:101..175 | L→R | 20/26 | — | — |
| 4 | 94 | 4.488 | 149×215 | 148 | **c88>c89>c90** | c88:119..176 c89:123..175 c90:118..175 **c91:145..175 c92:147..175** | L→R | 49/7 | — | **thumb rejected** — c91 `lng=31` c92 `lng=29` fall out of winning window; palm wins on low side |
| 5 | 128 | 5.602 | 161×210 | 232 | c88>c89>c90 | c88:199..264 c89:200..266 c90:199..264 | R→L | 14/35 | `#5 userY=173 Δy=-59`, `#5 userY=180 Δy=-52` | — |
| 6 | 163 | 6.778 | 127×201 | 258 | c88>c89>c90 | c88:220..298 c89:219..297 c90:219..298 | R→L | 28/22 | `#6 userY=187 Δy=-71`, `#6 userY=192 Δy=-66` | — |
| 7 | 197 | 7.906 | 140×214 | 247 | c88>c89>c90 | c88:202..294 c89:198..296 c90:198..295 | R→L | 19/32 | `#7 userY=160 Δy=-87`, `#7 userY=155 Δy=-92`, `#7 userY=166 Δy=-81`, `#7 userY=161 Δy=-86`, `#7 userY=187 Δy=-60`, `#7 userY=183 Δy=-64` | — |
| 8 | 230 | 9.020 | 147×215 | 147 | c89>c90>c91 | c88:118..174 c89:122..174 c90:123..174 c91:119..173 **c92:143..173** | L→R | 42/10 | — | **thumb rejected** — c92 `lng=31` drops out, winning window shifts away from it |
| 9 | 263 | 10.119 | 162×207 | 238 | c88>c89>c90 | c88:190..287 c89:189..286 c90:188..285 | L→R | 46/15 | — | — |
| 10 | 298 | 11.272 | 137×225 | 240 | c88>c89>c90 | c88:185..298 c89:183..296 c90:181..296 | R→L | 19/36 | `#10 userY=159 Δy=-81` | — |
| 11 | 332 | 12.411 | 130×213 | 245 | c88>c89>c90 | c88:194..299 c89:192..298 c90:189..298 | R→L | 28/27 | `#11 userY=151 Δy=-94` | — |
| 12 | 363 | 15.488 | 180×227 | 189 | c90>c91>c92 | c90:136..243 c91:137..243 c92:133..244 | L→R | 46/12 | — | (preceded by two `blob=180x305..180x320` GATE_DIAG noise close-misses on frames 359..362 — `need=76 avg=54` etc. — noise survived one more frame and tipped over threshold) |
| 13 | 392 | 16.428 | 63×106 | 226 | c88>c89>c90 | c88:191..245 c89:202..251 c90:215..254 | R→L | 0/10 | — | smallest blob of the run; preceded by three `fill_ratio<0.25` rejects |

### USER_MARK lines (verbatim)

```
[USER_MARK] #2 detY=206 userY=169 Δy=-37 userX=54 time=1.225
[USER_MARK] #5 detY=232 userY=173 Δy=-59 userX=98 time=5.602
[USER_MARK] #5 detY=232 userY=180 Δy=-52 userX=107 time=5.602
[USER_MARK] #6 detY=258 userY=187 Δy=-71 userX=20 time=6.778
[USER_MARK] #6 detY=258 userY=192 Δy=-66 userX=43 time=6.778
[USER_MARK] #7 detY=247 userY=160 Δy=-87 userX=86 time=7.906
[USER_MARK] #7 detY=247 userY=155 Δy=-92 userX=94 time=7.906
[USER_MARK] #7 detY=247 userY=166 Δy=-81 userX=96 time=7.906
[USER_MARK] #7 detY=247 userY=161 Δy=-86 userX=87 time=7.906
[USER_MARK] #7 detY=247 userY=187 Δy=-60 userX=91 time=7.906
[USER_MARK] #7 detY=247 userY=183 Δy=-64 userX=91 time=7.906
[USER_MARK] #10 detY=240 userY=159 Δy=-81 userX=103 time=11.272
[USER_MARK] #11 detY=245 userY=151 Δy=-94 userX=61 time=12.411
```

Crossings #5, #6, #7 were re-tapped multiple times to probe sensitivity
of the Δy at different userX positions — all re-taps stayed in the
negative cluster regardless of where along the gate line the user tapped.

### Aggregate observations

1. **Thumb reject works — confirmed via `winStart` marker.** Crossings #4
   and #8 both show the winning 3-col window explicitly *excluding* the
   columns whose longest run is tied to the thumb (c91/c92 on #4 with
   `lng=31/29`; c92 on #8 with `lng=31`). The sliding-window average
   finds the palm and settles there. This is the first direct evidence
   that the body-part / thumb reject works as designed on real input.
2. **`detY` is systematically *low* on hand swipes.** 8 of 8 paired
   USER_MARK lines have negative Δy, tight cluster −37 to −94 px on a
   320-px-tall frame (i.e. 12–29% too low vertically). Cross-checking the
   `@sY..eY` ranges against the blob `y` span:
   - #6 winning runs at `y≈219..298`, blob `119..319` → winning segment
     lives in the bottom 50% of the blob, not the center.
   - #7 winning runs at `y≈198..296`, blob `106..319` → same pattern.
   - #11 winning runs at `y≈189..298`, blob `107..319` → same.
   The "longest contiguous vertical run" is reliably settling at the
   **densest vertical stripe of the mask**, not at the leading edge of
   the body that actually crossed the gate column.
3. **This is the hand-swipe mirror of Test A's "early on lower leg"
   bias.** In Test A, detY was pulled to the shin when the shin was the
   mask-dense stripe. In Test B, detY is pulled to the wrist / heel of the
   palm because that is where the hand mask is densest (slowest-moving
   part of the swipe accumulates more `|Δ|≥15` pixels). Same root cause,
   different body parts — the detY-selection rule is the problem, not
   anything specific to running bodies.
4. **`maxGap` is large across the board** — most winning columns log
   `maxGap` in the 7–40 range, with a few 50+ on #6 and #7. The mask is
   gappy enough that "longest run" ≠ "where the blob really is".
5. **Close-miss GATE_DIAGs on frames 162, 196, 359–362** — the first two
   are partial-body close misses (`need≈51 avg≈40`) and the latter three
   are whole-frame noise (`blob=180x320..180x305`, `avg=73 need=80`)
   that tipped over the threshold into a real DETECT on frame 363
   (crossing #12). Not a wrong detection per the logs — just worth
   knowing that noise can edge into the gate after several near-misses.

### Gaps in this data

1. **No verdict on crossings 1, 3, 4, 8, 9, 12, 13** — user only tapped
   #2, #5, #6, #7, #10, #11. (#4 and #8 are interpreted from the thumb-
   reject evidence above, not from a USER_MARK.)
2. **No leading-edge Y candidate logged alongside `detY`.** We know where
   the longest run is, but we do not know what the *topmost* qualifying
   run is. Adding a "topY" column to DETECT_DIAG would tell us whether
   a better selection rule is even *reachable* with the current mask
   geometry.
3. **Frame drops between crossings #1 and #2** — a `[FRAME_DROP] 14
   frames dropped since frame 30` line means the 147 ms between #1 and
   #2 is missing ~14 frames of log context. Not a bug in the run, but
   the burst around the detection shows where processing is bottlenecked.

---

## Run 2026-04-06 Test C — slower hand swipes, Photo-Finish-style methodology

**Device / setup:** same as Test B (iPhone front camera, 30 fps,
hd1280x720, process 180×320, gate column 90, stabilization off, Center
Stage off, `scaleX=scaleY=4`).

**Build:** identical to Test B — no code changes between B and C, only
a physical change in how the swipe was performed.

**Purpose:** replicate the slow-motion hand-sweep tests used to probe the
**original Photo Finish app** (see `raw_test_results.md`). Test B ran
hand swipes at normal speed and revealed a systematic detY-low bias.
Test C deliberately slowed the motion down, so if the bias were caused
by frame drops / motion blur / auto-exposure latency we would expect
Test C to improve. If the bias is caused by the detY-selection rule
itself (longest vertical run picks the densest stripe, not the leading
edge), Test C would look the same or worse.

### Detector algorithm state

**Unchanged from Test B.** Identical to Test A's 18-stage pipeline +
parameter table.

### Run: 10 crossings

| # | frame | time (s) | blob (W×H) | detY | win | winning col Y-ranges (key) | dir | interp dB/dA | USER_MARK Δy |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 42 | 1.392 | 107×114 | 273 | c88>c89>c90 | **c88:278..319 c89:274..319 c90:206..244** (c90 disjoint from c88/c89) c91:270..318 c92:268..315 | R→L | 31/0 | — |
| 2 | 99 | 3.271 | 140×307 | 161 | c90>c91>c92 | c88:34..289 c89:34..288 c90:35..287 c91:37..284 c92:36..285 | L→R | 26/47 | — |
| 3 | 466 | 15.517 | 126×239 | 145 | c90>c91>c92 | c88:96..226 c89:96..225 c90:95..223 c91:95..180 c92:95..182 | L→R | 29/15 | — |
| 4 | 518 | 17.248 | 109×224 | 256 | c90>c91>c92 | c88:232..288 c89:232..286 c90:229..285 c91:229..284 c92:228..283 | L→R | 21/15 | **−81** (userY=175) |
| 5 | 627 | 20.872 | 118×121 | 219 | c88>c89>c90 | c88:199..239 c89:199..239 c90:199..238 c91:262..302 c92:260..301 | R→L | 9/25 | **−46** (userY=173) |
| 6 | 680 | 22.646 | 115×123 | 240 | c88>c89>c90 | **c88:197..239 c89:197..238 c90:262..305** (c90 disjoint from c88/c89) c91:260..304 c92:261..303 | R→L | 0/0 | **−49** (userY=191) |
| 7 | 732 | 24.384 | 121×124 | 281 | c88>c89>c90 | c88:262..304 c89:259..303 c90:259..303 c91:254..301 c92:254..301 | R→L | 21/13 | **−107** (userY=174) |
| 8 | 783 | 26.080 | 147×226 | 175 | c90>c91>c92 | c88:109..244 c89:113..242 c90:110..240 c91:110..240 c92:113..240 | L→R | 19/19 | **+11** (userY=186) |
| 9 | 910 | 31.822 | 180×320 | 103 | c90>c91>c92 | c90:0..119 (whole-frame noise blob) | L→R | 80/25 | — |
| 10 | 914 | 32.674 | 180×320 | 246 | c90>c91>c92 | c90:173..319 (whole-frame noise blob) | L→R | 50/89 | — |

### USER_MARK lines (verbatim — note the reverse order the user tapped)

```
[USER_MARK] #8 detY=175 userY=186 Δy=+11  userX=9  time=26.080
[USER_MARK] #7 detY=281 userY=174 Δy=-107 userX=7  time=24.384
[USER_MARK] #6 detY=240 userY=191 Δy=-49  userX=4  time=22.646
[USER_MARK] #5 detY=219 userY=173 Δy=-46  userX=29 time=20.872
[USER_MARK] #4 detY=256 userY=175 Δy=-81  userX=28 time=17.248
```

### Important inter-crossing close-misses

These are not crossings — they are `GATE_DIAG` + `REJECT local_support`
close-miss pairs that fired between successful detections. They matter
because the maxGap values reveal how fragmented the slow-motion mask is.

| frame | blob | need | avg | maxGap (c88..c92) | notes |
|---|---|---|---|---|---|
| 465 | 96×214 | 53 | 51 | **98/96/115/120/118** | first clear evidence that slow motion *widens* maxGap to 100+ px |
| 626 | 116×222 | 55 | 45 | 89/91/88/87/88 | preceded crossing #5 |
| 679 | 113×218 | 54 | 53 | 66/85/85/85/81 | preceded crossing #6 |
| 731 | 110×217 | 54 | 49 | 100/103/101/101/100 | preceded crossing #7 |
| 782 | 118×211 | 52 | 44 | 93/91/102/102/102 | preceded crossing #8 |

All five close-misses are essentially one slow swipe each — the blob
took multiple frames to build enough `|Δ|` mass to clear `need`, and in
each case the final DETECT came 1 frame after the last GATE_DIAG.

### Aggregate observations

1. **Slower motion does *not* reduce the detY bias.** 4 of 5 marked
   crossings are still low, with Δy in the −107..−46 cluster. The bias
   cannot be blamed on motion blur or frame drops — it is inherent to
   the detY-selection rule.

2. **Averaging of disjoint column runs is a distinct failure mode** —
   visible *only* because of the `lng=N@sY..eY` logging added after
   Test A:
   - **Crossing #1:** winning window c88>c89>c90. c88:278..319 (`mid≈298`),
     c89:274..319 (`mid≈296`), but **c90:206..244** (`mid≈225`). The
     three mid-points are ~298, ~296, ~225 → average ~273, which is what
     `detY=273` in the log shows. The winning window is averaging
     across a 70-pixel Y gap between c89 and c90.
   - **Crossing #6:** winning window c88>c89>c90. c88:197..239 (`mid≈218`),
     c89:197..238 (`mid≈217`), but **c90:262..305** (`mid≈283`). Average
     ~239 → `detY=240`. This detY is in a Y-zone where *no column has a
     run at all* — it is literally between two body parts.
   
   This failure cannot be fixed by biasing the rule "upward" or
   "downward". It requires detecting that the columns in the winning
   window disagree about where the body is, and then rejecting the
   window or picking a consensus range.

3. **Crossing #8 is the first *positive* Δy we have ever captured.**
   `detY=175 userY=186 Δy=+11`. The detY-low bias is **not monotonic**
   — detY can err in either direction depending on which subsegment of
   the mask happens to be densest. This rules out "shift midpoint up by
   N" as a fix.

4. **`maxGap` increased dramatically in Test C vs Test B.** Test B's
   typical winning-column maxGap was 7–40 (with a couple of 50+
   outliers); Test C's close-miss maxGaps are a repeated 80–120 band.
   **Hypothesis (do not act on yet):** slower motion means
   frame-to-frame `|Δ|` is smaller, so fewer pixels clear the
   `diffThreshold=15` cutoff, so the binary mask becomes more
   fragmented, so there are more intra-blob gaps, so the "longest run"
   drops to whatever subsegment survives fragmentation. If this
   hypothesis is right, `diffThreshold` is too high for slow motion.

5. **Thumb reject not exercised in Test C** — the user ran plain palm
   swipes, not thumb-out swipes. The Test B thumb-reject evidence
   (#4, #8) is the current authoritative data on that behavior.

6. **Crossings #9 and #10 are whole-frame noise** — `blob=180x320`, both
   at the end of the run within ~850 ms of each other. Almost certainly
   the user's hand very close to the camera or an auto-exposure flash.
   These are not representative of the rule being tested and should be
   ignored when tuning.

### Gaps in this data

1. **No user verdict on crossings 1, 2, 3, 9, 10** — 9 and 10 are
   whole-frame noise so they are expected-bad, but 1, 2, 3 would have
   been useful to confirm the disjoint-range failure actually produced
   a visually-wrong dot (we can infer it from the geometry but it is
   not verified against the user's eye).
2. **No *topmost* run Y logged alongside the longest run.** Same gap as
   Test B — we cannot yet tell whether the "use topmost qualifying run"
   selection rule would have picked the right body part, because we
   aren't logging the topmost run's Y range.

### Comparison vs. Test B

| dimension | Test B | Test C | delta |
|---|---|---|---|
| speed | normal | slow | |
| crossings | 13 | 10 | |
| USER_MARK points | 13 (re-taps) | 5 | |
| Δy sign | 8/8 negative | 4/5 negative, 1 positive | first ever +Δy |
| Δy range | −37..−94 | −46..−107 (+11 outlier) | slightly wider on Test C |
| typical maxGap | 7..60 | 80..120 (close-misses) | much larger on Test C |
| disjoint-range artifact | not observed | #1 and #6 | new failure mode |
| thumb-reject exercise | #4, #8 | not tested | — |

The running narrative is:

- **Test A (running bodies):** detY too low, "early on lower leg."
- **Test B (fast hand swipes):** detY too low, "on wrist / heel of palm."
  Same root cause, different subject.
- **Test C (slow hand swipes):** detY still mostly too low, *plus* a new
  disjoint-range averaging artifact, *plus* the first positive Δy.
  Slower motion does not help — in fact the mask gets *more* fragmented.

The detY-selection rule is the bug. Part C of the plan lists the three
candidate fixes (reject disjoint-range windows, prefer topmost qualifying
run, tighten diffThreshold / add morphological closing). Pick one and
test D will validate it.

---

## Run 2026-04-06 Test D — hand swipes (front camera, sparse low-energy)

**IMPORTANT label:** these are **hand swipes**, NOT real bodies. This run
was *intended* to be Phase 1 / Session 1 of the
`glittery-stargazing-matsumoto` plan (real-body data collection), but the
crossings that came in are once again hand-only. Phase 1 real-body data
is therefore **still pending**. Logging this run anyway because it gives
us another low-energy hand-swipe sample to compare against Test B/C, and
because the high reject density is itself diagnostic.

Per user instruction: **do not change the algorithm yet** — just log the
data and continue analyzing.

**Device / setup:** iPhone, **front camera** (ISO range 1100–1900,
exp ≈ 4.17 ms vs cap 4.00 ms — i.e. AE pinned at the cap), gate column =
center (x = 90 in process coords). Same gate position as Tests A–C.

**Build:** unchanged from Test C — same commit `307b689` plus the
same-session `[GATE_DIAG]` / `[DETECT_DIAG]` instrumentation. **No
algorithm change** between Test C and Test D. The detector snapshot in
Test A still applies verbatim — see "Detector algorithm snapshot" above.

### Crossings (3 successful detections)

| # | frame | time (s) | blob WxH | hR / wR | fill | run/need | dir | dB / dA | fraction | detY | exp / iso |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 172 | 7.445 | 124×123 | 0.38 / 0.69 | 0.34 | 30 / — | L>R | 4 / 14 | **0.22** | 200 | 4.17 ms / 1841 |
| 2 | 357 | 14.190 | 162×136 | 0.43 / 0.90 | 0.32 | 36 / — | L>R | 22 / 20 | **0.52** | 213 | 4.17 ms / 1841 |
| 3 | 487 | 18.524 | 138×120 | 0.38 / 0.77 | 0.39 | 30 / — | L>R | 14 / 14 | **0.50** | 192 | 4.17 ms / 1841 |

- All three crossings are L>R. No R>L sample at all in this run.
- Blob heights cluster 120–136, widths 124–162: consistent open-palm
  geometry, slightly larger than Test B/C palms (probably hand closer to
  camera or fingers more spread).
- `fill` is 0.32–0.39 — comfortably above the 0.25 floor but well below
  the ~0.5 you'd expect from a real torso.
- `hR` only 0.38–0.43 — hands are *barely* clearing the 0.33 height
  prefilter. A slightly less open palm or a more wrist-only swipe would
  be killed by the size prefilter alone, which explains the heavy
  `height` reject count (see below).

### Sub-frame fraction summary

| run | n | mean fraction | range | bias direction |
|---|---|---|---|---|
| Test B (fast hand swipes) | 13 | (not aggregated, per-crossing) | — | — |
| **prior 16-crossing hand swipe run** | 16 | **0.69** | 0.12 – 0.97 | late |
| **Test D (this run)** | 3 | **0.41** | 0.22 – 0.52 | early-ish |

3 data points are not statistically meaningful — do **not** read this as
"the bias flipped". The honest read is: the prior 0.69 number was over
16 hand swipes and is the only number in this dataset large enough to
even attempt a uniform-distribution test. This run is too small to
contradict it. We need real-body data, not more hand-swipe samples, to
move the X-interpolation question forward.

### Reject summary (counts only — full list in raw log)

Categories observed in the [REJECT] stream during this run:

| reason | rough count | notes |
|---|---|---|
| `height < 105` | very high (dozens) | small/partial hand fragments below the 0.33×320 floor |
| `fill_ratio < 0.25` | high | sparse hand swipes — palm with finger-gap holes; area/(W×H) too low |
| `no_gate_intersection` | moderate | blob never reached the gate band [88, 92] |
| `local_support < need` | moderate | gate touched, but average longest-run inside the 3-col window failed |
| `aspect_ratio > 1.2` | low–moderate | wide-flat hands, horizontal sweeps, mostly fingers without palm |

The dominant rejecter on this run is the `height` prefilter, then
`fill_ratio`. That matches "low-energy, sparse, near-threshold hand
motions" — i.e. the user was sweeping with less commitment than in the
prior 16-crossing run, so most attempts never even formed a blob big
enough to clear stage 6 of the pipeline.

### `[GATE_DIAG]` close-misses

These are the rejections where the local-support averaging *almost*
passed (`overallBestAvg ≥ 0.7 × need`). They are diagnostic because they
tell us the leading-edge scoring is sitting right at threshold for this
hand geometry:

| pattern | examples observed |
|---|---|
| `need=29 avg=27` | several |
| `need=30 avg=29` | several |
| `need=31 avg=23..25` | several |

Pattern: `need` is computed from blob height (`localSupportFraction = 0.25`
× height), so `need ≈ 30` corresponds to a blob of height ~120. The
window average is sitting 1–8 pixels below threshold, repeatedly. This
is the same "barely-failing local support" zone we saw in Test B/C —
hands have a leading-edge run that *almost* qualifies, and small
mask-noise differences flip the verdict.

This is **not new evidence** of an algorithm bug — it's the expected
behavior of the existing rule under hand-swipe geometry. Logging it for
completeness.

### `[FRAME_DROP]` cold-start (still firing)

After CROSSING #1 there is a `[GAP] 620 ms` followed by a
`[FRAME_DROP] 16` line. This is the same cold-start vImage allocation
issue that was identified earlier this session and explicitly deferred
in the plan. Listed here so we don't double-count it as a Test D
finding.

### What this run does *not* tell us

1. **Nothing about real bodies.** Phase 1 / Session 1 of the plan is
   still outstanding. Until we get walking/jogging crossings, we cannot
   say whether the X-interpolation bias from the prior hand-swipe run
   transfers to torsos, and we cannot test whether `body_part_suppression`
   fires correctly on legs/arms.
2. **Nothing about R>L motion.** All three detections are L>R. Any
   directional bias in the leading-edge scan stays untested in this run.
3. **Nothing definitive about the X-interpolation hypothesis.** Mean
   fraction 0.41 over 3 samples is consistent with anything in
   `[0.0, 1.0]` — the standard error is too large to confirm or refute
   the 0.69 number from the previous hand-swipe run.
4. **Nothing about the disjoint-range artifact** — none of the 3
   crossings exhibit it (Test C identified this on slow swipes; this
   run was different speed/geometry).

### Carry-over from prior tests (still open)

- **Y-row picker bias** (Tests A/B/C): detY lands too low. detY values
  here are 192, 200, 213 — for blobs of height 120–136 with `comp.minY`
  presumably around 60–90, those Y values are mid-to-lower body. Same
  shape as the prior bias. **Not in scope this pass per the plan** —
  Y is secondary, X is primary.
- **X-interpolation bias** (the prior 16-crossing run): unverified by
  this run; needs real bodies to move forward.
- **Cold-start frame drop**: still firing after crossing #1. Deferred.

### Action

**No algorithm change.** Per user: log the data, keep analyzing, do not
touch the detector until we have real-body crossings to compare
against. Phase 1 / Session 1 (real bodies) and Session 2 (bottle/book
control) are still required before Phase 2/3 of the plan can proceed.

---

## Run 2026-04-06 Test E — hand swipes after Phase 0 (cyan line landed)

**IMPORTANT label:** these are **hand swipes**, NOT real bodies. Two
back-to-back informal sessions captured immediately after the Phase 0
cyan-interpolated-gate-line UI change landed (`ContentView.swift` cyan
`Rectangle()` + yellow detector dot moved from center to `shiftedLayoutX`).
**No Phone B running Photo Finish in parallel**, but per user
clarification (correcting an earlier wrong assumption in this section):
the `[USER_MARK]` X values **ARE intended as Photo Finish reference
positions** — the user tapped where they believed PF would have drawn
its dot, based on familiarity with the PF app. They are a **less
rigorous** PF reference than a true Phone-B parallel session, but they
should be treated as PF references for analysis, not as freeform taps.
The formal two-phone Phase 1 parallel session is still pending and will
be Test F.

**X-only emphasis (per user):** in this run and going forward, only the
`userX` value matters for cyan-line comparison. The `userY` is essentially
random within the body's vertical extent — for a tall crossing object the
user can tap anywhere on the vertical strip and it counts as "right".
Δy values logged below are kept for completeness but should NOT be
analyzed as Y accuracy data in this run.

The purpose of Test E was twofold:
1. Validate that the new cyan line + relocated yellow dot render correctly
   in the fullscreen viewer (visual sanity check by the user).
2. Look at fraction distribution and reject density on hand swipes at
   different speeds.

Per user instruction: **do not change the algorithm yet**.

**Build:** Phase 0 changes only — `DetectionEngine.swift:79` removed
`private` from `gateColumn`, and `ContentView.swift:61–106` added the
cyan interpolated gate line + relocated the yellow detector dot from
horizontal center to `shiftedLayoutX`. **No detection-pipeline code
changed** between Test D and Test E.

**Device / setup:** iPhone, **front camera** (ISO 1690–1920, exp pinned
at 4.01 ms vs cap 4.00 ms). Same gate column 90.

### Sub-run E.1 — faster mixed swipes, 10 crossings

| #  | frame | time (s) | blob WxH | dB / dA | dir | frac | frame chosen | detY |
|----|---|---|---|---|---|---|---|---|
| 1  | 45  | 1.466  | 162×220 | 56 / 7  | L>R | **0.89** | curr (N)   | 253 |
| 2  | 63  | 2.634  | 170×222 | 55 / 5  | L>R | **0.92** | curr (N)   | 239 |
| 3  | 95  | 3.680  | 180×214 | 21 / 54 | L>R | **0.28** | prev (N-1) | 277 |
| 4  | 126 | 4.727  | 166×223 | 31 / 14 | L>R | **0.69** | curr (N)   | 193 |
| 5  | 159 | 5.817  | 180×205 | 24 / 41 | L>R | **0.37** | prev (N-1) | 274 |
| 6  | 197 | 7.093  | 180×197 | 30 / 16 | L>R | **0.65** | curr (N)   | 245 |
| 7  | 238 | 8.440  |  89×121 | 1  / 22 | R>L | **0.04** | prev (N-1) | 220 |
| 8  | 285 | 10.022 |  48×106 | 2  / 2  | R>L | **0.50** | curr (N)   | 183 |
| 9  | 330 | 11.520 | 117×115 | 10 / 13 | L>R | **0.43** | prev (N-1) | 244 |
| 10 | 370 | 12.844 | 143×226 | 13 / 67 | L>R | **0.16** | prev (N-1) | 286 |

**Sub-run aggregate:**
- **Mean fraction = 0.493** (essentially ideal 0.5)
- Range: 0.04 – 0.92, roughly uniform
- 8 L→R + 2 R→L — first run with both directions in the same session
- Two near-miss `[GATE_DIAG]` events: frame 158 (need 51 avg 45) and
  frame 236 (need 56 avg 52). One `[REJECT] body_part_suppression` on
  frame 196 (gate_area=4367 vs approaching_area=4846 dist=11) — this is
  the only suppression event in either sub-run.
- **Cold-start `[FRAME_DROP]`**: frame 47 had `[GAP] 611ms` and
  `[FRAME_DROP] 16` immediately after crossing #1 (= same known
  `prewarmThumbnail` cold-start, deferred).

### Sub-run E.2 — slow swipes, 5 crossings, many missed

| # | frame | time (s) | blob WxH | dB / dA | dir | frac | frame chosen | detY |
|---|---|---|---|---|---|---|---|---|
| 1 | 53  | 1.716  | 107×110 | 3  / 5  | L>R | **0.38** | prev (N-1) | 228 |
| 2 | 96  | 3.647  |  56×126 | 6  / 14 | L>R | **0.30** | prev (N-1) | 123 |
| 3 | 161 | 5.816  | 112×122 | 4  / 7  | L>R | **0.36** | prev (N-1) | 243 |
| 4 | 219 | 7.752  |  78×118 | 10 / 14 | L>R | **0.42** | prev (N-1) | 123 |
| 5 | 544 | 18.581 |  71×109 | 4  / 15 | R>L | **0.21** | prev (N-1) | 287 |

**Sub-run aggregate:**
- **Mean fraction = 0.334** (biased EARLY, opposite of the prior 16-swipe
  run's 0.69 bias)
- All 5 used the previous frame
- **All 5 have `dA > dB`** in the contiguous-mask scan, in BOTH directions
- Detection rate is dramatically degraded — between crossings #4 and #5
  there is a **17-second gap** (frame 220 → frame 543) populated almost
  entirely by `[REJECT]` lines: dozens of `fill_ratio` rejects (areas
  ~744–5827, ratios 0.10–0.25), several `local_support` rejects, several
  `aspect_ratio` rejects (1.4 ratio), several `no_gate_intersection`
  rejects, and one `[GATE_DIAG]` close-miss at frame 445 (need 27 avg 22)
- The user observed live: "it almost looks worse on slow crossings… it
  actually missed a few crossings"
- Cold-start `[GAP] 571ms` + `[FRAME_DROP] 5` and `[FRAME_DROP] 10` after
  crossing #1 — same known issue

### Combined fraction picture (Tests B + D + E.1 + E.2)

| run | n  | mean fraction | bias | notes |
|---|---|---|---|---|
| prior 16-swipe (no Test letter) | 16 | **0.69** | late  | initial signal |
| Test D                          |  3 | **0.41** | (n=3, not significant) | front cam, low energy |
| Test E.1 (faster, mixed)        | 10 | **0.49** | none  | first L+R mix, looks ideal |
| Test E.2 (slow only)            |  5 | **0.33** | early | direction-flip from prior 16 |

Combined `n = 34` hand-swipe crossings. The bias direction is NOT
consistent across runs — fast swipes are running close to ideal (E.1),
slow swipes are biased EARLY (E.2), and the original 16-swipe run was
biased LATE (0.69). **Three runs, three different bias directions.**

This rules out the simplest version of the "trailing-edge body-texture
pollution" hypothesis from the original plan, which would have predicted
a consistent LATE bias (`fraction > 0.5`) on every hand-swipe run because
the contiguous-mask scan would always walk into body interior on the
trailing side. We do not see that.

Possible alternative explanations (none tested yet):
1. **Bias depends on motion characteristics** (speed, leading-edge sharpness,
   sub-frame phase relative to capture clock), not on the algorithm
   geometry alone.
2. **`fraction` is just noisy** for hand-swipe crossings because palm
   geometry is irregular, and the apparent biases per run are sample
   variation. With 5–16 points per run we cannot distinguish noise from
   bias.
3. **Slow-specific bias** — there is a real early bias on slow swipes
   that we are seeing for the first time in E.2, separate from any
   fast-swipe behavior.

Need more data to choose between these — and ideally Photo Finish ground
truth to anchor what "correct" actually looks like, since right now we
are comparing our `fraction` to a theoretical 0.5 derived from "ideally
uniform random sub-frame timing", which assumes the user is tapping
randomly with respect to the 30 fps clock. That assumption may itself
be wrong — humans don't tap perfectly randomly.

### Why `[USER_MARK]` X is NOT useful in this run

The `[USER_MARK]` lines logged in Test E look like:

```
[USER_MARK] #1 detY=253 userY=173 Δy=-80 userX=58 time=1.466
[USER_MARK] #6 detY=245 userY=236 Δy=-9 userX=4 time=7.093
[USER_MARK] #10 detY=286 userY=161 Δy=-125 userX=87 time=12.844
```

userX values across E.1 are scattered: `58, 57, 76, 56, 86, 4, 48, 30,
33, 87`. They do not correlate with the cyan line position
(`gate ± dB or ± dA`) for any consistent rule. This is expected — there
was no Phone B, so the user was tapping freeform on the thumbnail (eye
on the body, not on a PF reference). **These userX values must NOT be
treated as ground truth in any comparison going forward.** Δy values
(–9 to –128) confirm the same Y-row-picker bias seen in Tests A/B/C, but
that is out of scope per the plan.

When the formal Phase 1 two-phone PF parallel session lands, a separate
"Test F" section will be created for it.

### Y-row picker carry-over (deferred but logged)

For posterity: detY values in E.2 are 228, 123, 243, 123, 287. Two of
those (#2 and #4) are at row 123 — that is up in the top portion of the
frame. Looking at #2, blob is 56×126 at `y=50..175`, so detY=123 is
near the bottom of that blob (row 123 vs blob bottom 175). Same pattern
as Tests A/B/C — `analyzeGate` lands detY too low on the blob. Not
fixed in this pass; logged for the future Y-row pass.

### Action

**No algorithm change.** Append more data, especially:
1. **More slow-crossing samples** to confirm whether the E.2 early bias
   is real or a 5-sample artifact.
2. **The formal two-phone Phase 1 PF parallel session** (the data that
   actually unblocks Phase 3).
3. **Cyan-line visual sanity check from the user** — pinning down
   whether "looks worse on slow" means (a) more missed detections,
   (b) cyan dot X visually misaligned with hand leading edge, or
   (c) cyan dot Y visually wrong (= the known Y-picker bias).

---

## Run 2026-04-07 Test F — upright + forward-lean finishes (no leg swipes)

**Device / setup:** iPhone, back camera, tripod, gate column = center
(x=90 in process coords). Auto-exposure with cap 4.00 ms, well-lit indoor
(ISO range 270–870 across the run). `.hd1280x720` preset, `420v` pixel
format, 30 fps locked.

**Build:** identical algorithm and parameters to Test E (Run 2026-04-06 §
Test A snapshot). **Zero detector code changed since 2026-04-06** — this
run is a pure data-collection pass against the same binary that produced
the Test F hypotheses doc (`detector_hypotheses.md`, dated 2026-04-06).

**User-declared scenario plan:**
- **Laps 1–13:** upright sprint crossings (regular running form).
- **Laps 14, 15, 16:** forward-lean finishes (chest-over-line lean,
  reduces vertical body extent in the visible blob).
- **Lap 17:** upright (extra crossing after the lean set).
- **No leg-swipe / hand-only crossings in this session.** The leg-fire
  hypothesis from `detector_hypotheses.md` cannot be tested with this
  data — leg-swipe runs will follow in a separate "Test G" session.

Cold-start artifacts (already known, not lean-related):
- `[GAP] 608ms gap before frame=32`
- `[FRAME_DROP] 4 frames dropped since frame 32`
- `[FRAME_DROP] 11 frames dropped since frame 33`

The cold-start gap landed between crossing #1 and crossing #2 — those
two crossings are 0.751 s apart in `[CROSSING]` time but the engine
processed almost no frames in between because of the drop. This is the
same `processFrame`-vs-capture-thread cold-start issue from prior runs
and is being tracked separately.

### Run: 17 crossings

| # | time (s) | type | blob (W×H) | hR | wR | fill | detY | dir | interp dB/dA | frame |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 0.939 | upright | 129×136 | 0.43 | 0.72 | 0.31 | 274 | R→L | 1/12 | 30 |
| 2 | 1.690 | upright | 107×206 | 0.64 | 0.59 | 0.35 | 193 | L→R | 24/16 | 35 |
| 3 | 6.363 | upright | 127×203 | 0.63 | 0.71 | 0.38 | 165 | L→R | 18/6 | 175 |
| 4 | 10.393 | upright | 95×246 | 0.77 | 0.53 | 0.29 | 286 | L→R | 7/4 | 296 |
| 5 | 17.152 | upright | 98×231 | 0.72 | 0.54 | 0.30 | 275 | L→R | 5/9 | 499 |
| 6 | 20.749 | upright | 104×251 | 0.78 | 0.58 | 0.42 | 186 | R→L | 2/6 | 607 |
| 7 | 23.654 | upright | 112×249 | 0.78 | 0.62 | 0.33 | 236 | L→R | 3/5 | 694 |
| 8 | 33.790 | upright | 127×264 | 0.82 | 0.71 | 0.41 | 270 | R→L | 7/11 | 998 |
| 9 | 37.061 | upright | 126×281 | 0.88 | 0.70 | 0.35 | 124 | L→R | 0/0 | 1096 |
| 10 | 42.131 | upright | 103×243 | 0.76 | 0.57 | 0.34 | 203 | R→L | 5/4 | 1248 |
| 11 | 44.828 | upright | 159×255 | 0.80 | 0.88 | 0.32 | 240 | L→R | 4/5 | 1329 |
| 12 | 48.405 | upright | 151×233 | 0.73 | 0.84 | 0.27 | 261 | R→L | 12/4 | 1436 |
| 13 | 51.448 | upright | 49×152 | 0.47 | 0.27 | 0.28 | 200 | R→L | 9/0 | 1527 |
| **14** | **55.462** | **lean fwd** | **46×166** | **0.52** | **0.26** | **0.29** | **283** | **R→L** | **4/6** | **1648** |
| **15** | **58.280** | **lean fwd** | **133×227** | **0.71** | **0.74** | **0.25** | **247** | **R→L** | **33/3** | **1732** |
| **16** | **61.761** | **lean fwd** | **117×232** | **0.73** | **0.65** | **0.27** | **166** | **R→L** | **4/8** | **1837** |
| 17 | 68.308 | upright | 77×225 | 0.70 | 0.43 | 0.26 | 183 | L→R | 9/4 | 2033 |

### USER_MARK ground-truth Δy (final mark per lap)

Y is processing-buffer Y (180×320, 0 = top of image). **Δy = userY − detY**,
so negative means **detector picked a Y *below* the user's torso mark**
(deeper into the body, toward feet).

| # | type | detY | userY | Δy | userX |
|---|---|---|---|---|---|
| 4  | upright  | 286 | 164 | **−122** | 87 |
| 5  | upright  | 275 | 170 | **−105** | 77 |
| 6  | upright  | 186 | 166 |   −20  | 92 |
| 7  | upright  | 236 | 170 |  **−66**  | 88 |
| 9  | upright  | 124 | 159 |  **+35**  | 87 |
| 11 | upright  | 240 | 234 |    −6  | 82 |
| 12 | upright  | 261 | 176 |  **−85**  | 92 |
| 13 | upright  | 200 | 183 |   −17  | 95 |
| **14** | **lean fwd** | **283** | **167** | **−116** | 108 |
| **15** | **lean fwd** | **247** | **180** |  **−67** | 174 |
| **16** | **lean fwd** | **166** | **161** |   **−5** |  90 |
| 17 | upright  | 183 | 162 |   −21  | 77 |

Laps 1, 2, 3, 8, 10 were not USER_MARK'd in this session.

**Headline numbers:**
- **11 of 12 marks have negative Δy** (detector picks Y *below* the
  torso mark on every lap except #9).
- Mean Δy ≈ **−47** (≈14.7% of 320-px frame height).
- Worst three offenders are **−122, −116, −105** — more than a third
  of the frame height between detector and user mark.
- Lap **#9** is the only positive (Δy = +35) and corresponds to the
  disjoint-range column pattern documented below.
- Lap **#16** (a lean!) is **the most accurate crossing of the entire
  session** at Δy = −5. Existence proof that leans are not inherently
  broken — they fail only when the gate column happens to slice
  through a foreleg/foot.

### High-signal DETECT_DIAG excerpts

#### Lap 4 (upright, Δy = −122) — clean longest-run-in-the-legs failure
```
[COMP] >>> #1 95x246 x=17..111 y=74..319 area=6784 gate=YES
[DETECT] blob=95x246 hR=0.77 wR=0.53 fill=0.29 run=62 interp=7/4 dir=L>R
   cands=1 area=6784 x=17..111 detY=286 frame=296 time=10.393
[DETECT_DIAG] frame=296 blob=95x246 need=61 avg=62
   cols=[ c88:lng=61@249..309/tot=164/runs=11/maxGap=36
       >  c89:lng=68@249..316/tot=152/runs=8/maxGap=44
       >  c90:lng=65@251..315/tot=132/runs=8/maxGap=80
       >  c91:lng=54@266..319/tot=132/runs=9/maxGap=82
          c92:lng=46@274..319/tot=132/runs=11/maxGap=85 ]
```
Blob spans `y=74..319` (a near-full-frame body). The longest run in
*every* gate column lives in `y ≈ 249..319`, i.e. the lower third of
the body. detY = midpoint of longest run = ~286. User marked the
upper torso at 164. The gate column is slicing legs/feet, not torso,
because the legs produced a denser/longer contiguous mask stripe than
the torso did.

#### Lap 9 (upright, Δy = +35) — disjoint-range artifact, real-body sighting
```
[COMP] >>> #0 126x281 x=7..132 y=39..319 area=12242 gate=YES
[DETECT] blob=126x281 hR=0.88 wR=0.70 fill=0.35 run=89 interp=0/0 dir=L>R
   cands=1 area=12242 x=7..132 detY=124 frame=1096 time=37.061
[DETECT_DIAG] frame=1096 blob=126x281 need=70 avg=89
   cols=[  c88:lng=146@140..285/tot=236/runs=5/maxGap=35
           c89:lng=136@143..278/tot=229/runs=6/maxGap=38
        >  c90:lng=155@145..299/tot=232/runs=3/maxGap=40
        >  c91:lng=58@46..103/tot=200/runs=5/maxGap=44
        >  c92:lng=56@47..102/tot=179/runs=7/maxGap=48 ]
```
**Confirms hypothesis #2 from `detector_hypotheses.md`** on a real body.
Columns 88–90 had huge runs centered around y≈210 (torso/legs region);
columns 91–92 had short runs at y≈75 (head/upper-torso region). These
two y-zones are **disjoint** (mid-blob gap), and the sliding-window
scoring averaged them. detY = 124 — a y-coordinate where *neither*
column actually had its longest run. This is the exact failure mode
predicted in `detector_hypotheses.md` §0 hypothesis #2 and §2.6, here
seen on a jogging body for the first time, not just on hand swipes.

#### Lap 14 (lean forward, Δy = −116) — lean-as-leg-fire
```
[COMP] >>> #0 46x166 x=74..119 y=154..319 area=2220 gate=YES
[COMP]     #1 102x246 x=78..179 y=74..319 area=5754 gate=YES
[DETECT] blob=46x166 hR=0.52 wR=0.26 fill=0.29 run=53 interp=4/6 dir=R>L
   cands=1 area=2220 x=74..119 detY=283 frame=1648 time=55.462
[DETECT_DIAG] frame=1648 blob=46x166 need=41 avg=53
   cols=[ >c88:lng=59@261..319/tot=61/runs=3/maxGap=94
       >  c89:lng=45@258..302/tot=61/runs=5/maxGap=91
       >  c90:lng=55@254..308/tot=62/runs=4/maxGap=87
          c91:lng=39@251..289/tot=62/runs=9/maxGap=83
          c92:lng=33@249..281/tot=60/runs=9/maxGap=80 ]
```
Two gate-touching components: a small 46×166 blob and a larger 102×246
blob. The picker chose the smaller one (`#0`) because of how
`hasQualifyingSlice` scores rather than raw area — note `cands=1`, so
the larger blob did not qualify on `analyzeGate`. All longest runs are
in `y=249..319` again; detY = 283 is on the foreleg, user marked the
chest at 167. The lean compressed the body vertically but the
longest-vertical-run picker still landed on the leg, just like an
upright leg-fire.

#### Lap 15 (lean forward, Δy = −67) — long downward stripe in lean
```
[COMP] >>> #0 133x227 x=47..179 y=93..319 area=7651 gate=YES
[DETECT] blob=133x227 hR=0.71 wR=0.74 fill=0.25 run=101 interp=33/3 dir=R>L
   cands=1 area=7651 x=47..179 detY=247 frame=1732 time=58.280
[DETECT_DIAG] frame=1732 blob=133x227 need=56 avg=101
   cols=[ >c88:lng=122@198..319/tot=122/runs=1/maxGap=0
       >  c89:lng=89@197..285/tot=121/runs=2/maxGap=2
       >  c90:lng=92@195..286/tot=124/runs=2/maxGap=1
          c91:lng=86@234..319/tot=125/runs=2/maxGap=2
          c92:lng=88@232..319/tot=125/runs=2/maxGap=2 ]
```
Lean produced a single very long contiguous downward stripe (122 px
in c88 — about 38% of the frame!) running from y=198 to y=319, i.e.
chest-down-through-feet. Picker took the midpoint of that stripe,
landing at detY=247 (mid-thigh region). User marked the top of the
chest at 180. Note `interp=33/3` is wildly asymmetric — the leading
edge had walked 33 columns past the gate at this row, suggesting the
detection frame fired well after chest-cross.

User's `userX = 174` for this lap is way off the gate band (gate is
at column 90); the X mark is unreliable here. Δy is still meaningful
because the picker math doesn't couple X and Y.

#### Lap 16 (lean forward, Δy = −5) — the existence proof
```
[COMP] >>> #0 117x232 x=63..179 y=88..319 area=7442 gate=YES
[DETECT] blob=117x232 hR=0.73 wR=0.65 fill=0.27 run=60 interp=4/8 dir=R>L
   cands=1 area=7442 x=63..179 detY=166 frame=1837 time=61.761
[DETECT_DIAG] frame=1837 blob=117x232 need=58 avg=60
   cols=[ >c88:lng=55@138..192/tot=138/runs=8/maxGap=60
       >  c89:lng=61@136..196/tot=142/runs=14/maxGap=53
       >  c90:lng=66@136..201/tot=141/runs=8/maxGap=46
          c91:lng=65@142..206/tot=143/runs=11/maxGap=40
          c92:lng=70@140..209/tot=151/runs=11/maxGap=34 ]
```
Same lean form as #14 and #15 — but here the longest run in every gate
column lives cleanly in the upper-torso band (`y ≈ 136..209`) with no
strong leg run competing. detY = 166 sits 5 px below the user's mark
of 161. **This is the most accurate crossing of the entire session,
and it's a lean.** It is the existence proof that leans are not
inherently broken: the failure is "which body part the gate column
happens to slice at frame T", not "leans are detected wrong".

### Observations / what this run actually tells us

1. **The Y-row picker bias is now confirmed on real bodies**, not just
   on the prior hand-swipe runs. 11 of 12 marks negative, mean −47.
   Promotes hypothesis #1 from `detector_hypotheses.md` from
   "predicted" to "observed bias direction".
2. **The disjoint-range artifact (hypothesis #2) is also confirmed
   on a real body** — see lap #9 above. First sighting outside hand
   swipes.
3. **The lean failure mode is the same Y-row picker bug surfaced
   through different geometry.** Not "leans reduce vertical height
   and break detection." It's "leans change which body part the gate
   column slices at frame T, and the picker takes whichever stripe is
   densest." Lap 14 (Δy=−116, leg-fire on lean) and lap 16 (Δy=−5,
   torso column on lean) are the both-directions existence proofs.
4. **Lean does NOT correlate with worse Δy in this run.** Mean lean
   Δy = (−116 − 67 − 5) / 3 = **−63**. Mean upright Δy (excluding the
   +35 outlier) = (−122 − 105 − 20 − 66 − 6 − 85 − 17 − 21) / 8 =
   **−55**. Within sample noise. Variance, not bias direction, is
   what differentiates the two scenarios in this run.
5. **No leg-swipe data was collected** — leg-fire hypothesis remains
   unconfirmed for this session. Track for the next test.

### Action

**No algorithm change.** The user has explicitly directed the
investigation order: forward-lean failure mode first, leg-in-front-of-
body second. The next physical test we need is a **parallel Photo
Finish capture of forward leans**, so we have ground truth for whether
PF detects at the chest (Δy ≈ 0) or also picks low. That single data
point decides whether the Y-row picker is what we should fix at all,
or whether PF picks low too and our problem is somewhere else
entirely.

See `detector_hypotheses.md` §10 for the updated hypothesis ranking
that incorporates Test F evidence.

---

## Run 2026-04-07 Test G — front-cam lean variations, PF-anchored marks

> **⚠️ USER_MARK SEMANTICS CHANGED FOR THIS RUN ⚠️**
>
> In Tests A–F the on-screen tap marked **body anatomy** (chest/torso),
> i.e. the user's best guess at where the runner's chest crossed. In
> **Test G the tap marks where Photo Finish places its dot on our lap
> thumbnail** — i.e. the user opened PF and ours side-by-side and
> tapped our thumbnail at the **same vertical position** PF chose on
> the same physical crossing.
>
> Therefore **`USER_MARK Δy` in Test G means `our_detY − PF_dotY`, NOT
> `our_detY − chest_truthY`**. **Do NOT pool Test G Δy values with
> Tests A–F.** They are measured against different reference axes and
> averaging them is meaningless. The success metric for Test G is "how
> close did our picker land to PF's picker on the same blob," not "how
> close did we land to anatomical truth."
>
> Per CLAUDE.md and the project memory `feedback_replicate_not_improve_pf.md`,
> the goal is to **replicate** PF's behavior, not to be more
> anatomically correct than PF.
>
> Per the user during this session, **PF times are NOT comparable**
> ("the times wont be compareable so its unessary to do this, what
> mattesr is my placement on the thumbnails"). The success metric for
> the picker fix is now **Y-placement on the thumbnail**, not T.

**Camera caveat:** This run was captured on the **front camera**. All
prior runs (A–F) were back camera. Cross-test comparison with Test F
is therefore not apples-to-apples — front-cam framing, FOV, and
auto-exposure behavior differ.

### Run setup

- 11 gate crossings, single runner
- Mixed lean variations (the user pre-labelled each crossing as
  "more lean", "less lean", or "no lean")
- Front camera, otherwise default detector params (the same binary
  that produced the Test F run earlier today)
- Of 11 crossings, 8 received PF-anchored taps; 3 (#6, #8, #10) were
  not tapped, so we have only the lean-variation label for them
- Crossing #1 was tapped twice — first tap (Δy=−74) was a fat-finger,
  second tap (Δy=−76) is the correction. Use only the second.

### Detector results — full 11-crossing run table

All blobs gate=YES, all met heightFraction/widthFraction/run prefilters.

| # | t (s) | dir | blob WxH | comp y range | area | run | fill | hR | wR | detY |
|---|-------|-----|----------|--------------|------|-----|------|------|------|------|
| 1 | 6.121 | L>R | 70×169 | 151..319 | 3092 | 49 | 0.26 | 0.53 | 0.39 | 256 |
| 2 | 9.460 | L>R | 164×209 | 111..319 | 8595 | 86 | 0.25 | 0.65 | 0.91 | 264 |
| 3 | 12.987 | L>R | 100×195 | 125..319 | 6291 | 65 | 0.32 | 0.61 | 0.56 | 239 |
| 4 | 16.018 | L>R | 108×222 | 98..319 | 7645 | 64 | 0.32 | 0.69 | 0.60 | 183 |
| 5 | 19.620 | R>L | 107×223 | 97..319 | 8162 | 71 | 0.34 | 0.70 | 0.59 | 182 |
| 6 | 26.104 | R>L | 118×212 | 108..319 | 7998 | 53 | 0.32 | 0.66 | 0.66 | 175 |
| 7 | 28.827 | L>R | 84×222 | 98..319 | 5583 | 59 | 0.30 | 0.69 | 0.47 | 225 |
| 8 | 32.201 | R>L | 141×223 | 97..319 | 8099 | 65 | 0.26 | 0.70 | 0.78 | 197 |
| 9 | 39.002 | L>R | 107×157 | 143..299 | 4390 | 54 | 0.26 | 0.49 | 0.59 | 269 |
| 10 | 41.463 | L>R | 87×203 | 117..319 | 4543 | 58 | 0.26 | 0.63 | 0.48 | 181 |
| 11 | 44.503 | R>L | 112×196 | 124..319 | 5948 | 50 | 0.27 | 0.61 | 0.62 | 294 |

### USER_MARK Δy table — stratified by lean severity

`Δy = our_detY − PF_dotY` (negative = our picker is **below** where PF
placed its dot, i.e. lower in the frame / further into the legs).

`% from blob top = (PF_dotY − comp.minY) / comp.height` (where PF
landed within the blob, expressed as a fraction of blob height; 0% =
top of blob, 100% = bottom of blob).

`detY % from top` is the same fraction for our own picker, included
to make the gap visible without arithmetic.

| # | variation | detY | PF Y | **Δy** | PF % from top | detY % from top |
|---|-----------|------|------|--------|---------------|-----------------|
| 1 | more lean | 256 | 180 | **−76** | **17%** | 62% |
| 2 | more lean | 264 | 186 | **−78** | **36%** | 73% |
| 3 | more lean | 239 | 168 | **−71** | **22%** | 58% |
| 9 | more lean | 269 | 183 | **−86** | **26%** | 80% |
| 11 | more lean | 294 | 171 | **−123** | **24%** | 87% |
| 4 | less lean | 183 | 175 | −8 | 35% | 38% |
| 5 | less lean | 182 | 179 | −3 | 37% | 38% |
| 7 | no lean | 225 | 219 | −6 | 55% | 57% |
| 6 | less lean | (unmarked) | — | — | — | 32% |
| 8 | no lean | (unmarked) | — | — | — | 45% |
| 10 | less lean | (unmarked) | — | — | — | 32% |

**The bimodal split is clean and lines up perfectly with lean
severity, with zero overlap:**

- **More lean (n=5):** Δy ∈ {−76, −78, −71, −86, −123}, mean ≈ **−87**.
  Our detY % from top ranges 58–87% (lower-body band). PF % from top
  ranges 17–36% (upper-body band).
- **Less lean (n=2 marked):** Δy ∈ {−8, −3}, mean ≈ **−5.5**. Our
  detY % from top ≈ 38%. PF % from top ≈ 35–37%. **Picker matches.**
- **No lean (n=1 marked):** Δy = −6. Our detY % from top = 57%. PF
  % from top = 55%. **Picker matches.**

The 3 unmarked crossings (#6, #8, #10) have detY % from top in the
32–45% band — consistent with the marked less/no-lean cluster, which
strongly suggests they would also have shown small Δy if tapped.

### High-signal DETECT_DIAG excerpts — the "more lean" cluster (lower-body picker landing)

These are the 5 crossings where the picker dramatically misses PF.
Note that across c88..c92 the longest run in every column sits in
the lower portion of the blob. The picker is averaging midpoints of
these runs and landing in the leg/lower-body band. Above each run is
the PF dot Y for context.

```
#1  PF=180  comp y=151..319  blob 70x169
[DETECT_DIAG] frame=185 blob=70x169 need=42 avg=49 cols=[
  c88:lng=78@228..305/tot=93/runs=6/maxGap=60
  c89:lng=75@229..303/tot=83/runs=5/maxGap=6
  >c90:lng=67@230..296/tot=81/runs=5/maxGap=8
  >c91:lng=45@232..276/tot=69/runs=10/maxGap=7
  >c92:lng=36@234..269/tot=59/runs=9/maxGap=8 ]
  → all longest-runs start at y≈228-234 (i.e. 77-83 pixels below
    the blob's top edge at y=151). PF's dot is at y=180, only 29
    pixels below the top edge. The picker never even sees the
    upper-body pixels because the run that lives there is shorter
    than the leg run in the same column.
```

```
#2  PF=186  comp y=111..319  blob 164x209
[DETECT_DIAG] frame=285 blob=164x209 need=52 avg=86 cols=[
  c88:lng=67@230..296/tot=82/runs=9/maxGap=71
  c89:lng=70@228..297/tot=93/runs=12/maxGap=53
  >c90:lng=83@224..306/tot=97/runs=9/maxGap=46
  >c91:lng=83@223..305/tot=99/runs=9/maxGap=45
  >c92:lng=92@219..310/tot=108/runs=8/maxGap=31 ]
  → maxGap of 31..71 means there *are* upper-body pixels (the
    `tot` is up to 108 vs `lng` of 92), but they're broken up
    into shorter runs separated by big gaps. The picker only
    sees the longest run, which is the leg.
```

```
#3  PF=168  comp y=125..319  blob 100x195
[DETECT_DIAG] frame=391 blob=100x195 need=48 avg=65 cols=[
  c88:lng=62@203..264/tot=122/runs=6/maxGap=17
  c89:lng=63@204..266/tot=124/runs=6/maxGap=15
  >c90:lng=65@205..269/tot=129/runs=6/maxGap=13
  >c91:lng=65@207..271/tot=129/runs=7/maxGap=12
  >c92:lng=66@208..273/tot=132/runs=7/maxGap=11 ]
  → tot=122..132 vs lng=62..66 means the column is roughly half
    upper-body, half lower-body, but the lower stripe is the
    single longest contiguous run (and the upper is fragmented
    into runs separated by ≤17px gaps). Picker locks onto leg.
```

```
#9  PF=183  comp y=143..299  blob 107x157
[DETECT_DIAG] frame=1171 blob=107x157 need=39 avg=54 cols=[
  c88:lng=55@241..295/tot=80/runs=3/maxGap=13
  c89:lng=53@243..295/tot=78/runs=4/maxGap=10
  >c90:lng=52@244..295/tot=78/runs=4/maxGap=9
  >c91:lng=52@244..295/tot=79/runs=6/maxGap=3
  >c92:lng=59@238..296/tot=79/runs=4/maxGap=4 ]
  → blob is short (157px) but the longest run starts at y≈238-244
    (95-100px below the top edge at y=143). PF's dot at y=183 is
    only 40px below the top edge, well above any longest run in
    the gate columns.
```

```
#11  PF=171  comp y=124..319  blob 112x196   ← worst case, Δy=−123
[DETECT_DIAG] frame=1336 blob=112x196 need=49 avg=50 cols=[
  c88:lng=43@277..319/tot=97/runs=6/maxGap=56
  >c89:lng=44@276..319/tot=105/runs=9/maxGap=45
  >c90:lng=53@267..319/tot=108/runs=9/maxGap=32
  >c91:lng=53@267..319/tot=103/runs=6/maxGap=26
  c92:lng=54@266..319/tot=97/runs=6/maxGap=26 ]
  → longest runs start at y≈266-277 (142-153px below the top
    edge at y=124) and end at y=319 — these are LITERALLY THE
    FEET. The picker locks onto the feet. PF places its dot at
    y=171, only 47px below the top edge. tot=97-108 vs lng=43-54
    means roughly half the column is fragmented upper-body
    pixels, but no single contiguous upper run beats the foot
    run, so the picker never sees the body.
```

### High-signal DETECT_DIAG excerpts — the "less / no lean" cluster (picker matches PF)

These are the marked crossings where Δy is in the noise (≤8px). The
longest runs in c88..c92 happen to live at or near where PF's dot
goes — i.e. the runner's torso *is* the longest contiguous vertical
stripe in the gate columns when there is no significant lean.

```
#4  PF=175  comp y=98..319  blob 108x222
[DETECT_DIAG] frame=482 blob=108x222 need=55 avg=64 cols=[
  c88:lng=72@150..221/tot=125/runs=9/maxGap=75
  c89:lng=70@150..219/tot=97/runs=6/maxGap=90
  >c90:lng=69@149..217/tot=92/runs=6/maxGap=12
  >c91:lng=62@154..215/tot=94/runs=9/maxGap=8
  >c92:lng=62@151..212/tot=95/runs=8/maxGap=6 ]
  → longest runs span y≈149..221 (i.e. 51..123 below the top
    edge). PF dot at y=175 is 77 below the top edge — i.e.
    smack inside the longest run. Midpoint ≈ 184, picker
    averages to 183.
```

```
#5  PF=179  comp y=97..319  blob 107x223
[DETECT_DIAG] frame=590 blob=107x223 need=55 avg=71 cols=[
  >c88:lng=60@155..214/tot=146/runs=6/maxGap=50
  >c89:lng=64@153..216/tot=150/runs=8/maxGap=44
  >c90:lng=90@131..220/tot=171/runs=10/maxGap=23
  c91:lng=86@150..235/tot=177/runs=7/maxGap=17
  c92:lng=86@150..235/tot=175/runs=7/maxGap=17 ]
  → longest runs span y≈131..235 (mostly upper torso). Picker
    averages midpoints near 182. PF places dot at y=179. Match.
```

```
#7  PF=219  comp y=98..319  blob 84x222   ← "no lean" but PF lands at 55% from top
[DETECT_DIAG] frame=866 blob=84x222 need=55 avg=59 cols=[
  c88:lng=74@186..259/tot=84/runs=6/maxGap=15
  c89:lng=59@188..246/tot=82/runs=9/maxGap=13
  >c90:lng=57@192..248/tot=78/runs=8/maxGap=12
  >c91:lng=63@196..258/tot=85/runs=13/maxGap=6
  >c92:lng=59@201..259/tot=88/runs=13/maxGap=6 ]
  → longest runs span y≈186..259 (lower-mid torso / waist
    region). Picker averages to 225. PF places dot at y=219.
    Match. Note that this crossing demonstrates that PF
    is NOT just "upper-third of blob" — even on a no-lean
    runner, PF's dot is 55% of the way down the blob here.
    Whatever PF's rule is, it is not a flat fraction.
```

### Mechanism

The picker in `analyzeGate` (`DetectionEngine.swift:789-882`) takes
the **single longest contiguous vertical mask run** in each of the
gate columns c88..c92 and averages those run midpoints across a
sliding 3-column window. The y-row it returns (`detY`) is therefore
"the y-center of the longest contiguous vertical stripe in the gate
column."

- In an **upright body**, the torso is the single tallest contiguous
  vertical structure passing through the gate column. The picker
  lands on the torso, the runner's chest happens to be inside that
  stripe, and PF's dot also lands inside that stripe → Δy ≈ 0.

- In a **forward-leaning body**, the torso is rotated forward in
  the frame. The gate column no longer slices the torso as a single
  tall contiguous run — the torso pixels in the gate column become
  fragmented into shorter runs, separated by gaps where the gate
  column passes between an arm and a chest, or through a gap caused
  by the forward-rotated shoulder. Meanwhile the **legs are still
  vertical** in the gate column (feet + lower leg form one
  uninterrupted stripe from the body down to the bottom edge of the
  blob). The longest run in the gate column flips from "torso" to
  "leg," and the picker midpoint moves from the chest band down to
  the leg band. PF, empirically, continues to place its dot in the
  upper portion of the blob regardless of lean severity. So PF's
  picker is NOT "longest vertical run in gate columns."

This is the cleanest mechanistic confirmation we have for hypothesis
#1 to date: a monotonic relationship between lean severity and
picker error, with a clear, frame-by-frame visible cause (the gap
counts in the DETECT_DIAG output show exactly where the torso run
gets broken).

### Observations

1. **Δy correlates one-to-one with lean severity in this run.** Zero
   overlap between the more-lean cluster and the less/no-lean
   cluster. This is not noise — it is a systematic, lean-driven
   picker failure.
2. **PF does not have this bias.** Tests A–F speculated that PF might
   share the same low-bias on leans (in which case our detector would
   be "right" relative to PF and we shouldn't change anything). Test
   G falsifies that: PF visibly stays in the upper-body band on lean
   crossings while we drop to the legs. This is a divergence we must
   close, not a shared artifact.
3. **PF's rule is NOT "flat fraction of blob height."** Crossing #7
   ("no lean") puts PF at 55% from top, while crossings #1–3, #9, #11
   ("more lean") put PF at 17–36% from top. Whatever PF does, it
   adapts to body posture. A simple `detY = comp.minY + 0.25 * height`
   replacement would not match it.
4. **Front-camera caveat.** All prior tests were back camera. This
   run is front camera. Don't generalize Test G distribution
   characteristics (frame counts, gap sizes, motion-area
   distribution) to back-cam runs without re-checking.
5. **The current DETECT_DIAG output is insufficient to design the
   fix.** We log the single longest run per column (`lng=L@Y1..Y2`)
   but not the topmost run, the second-longest run, or the topmost
   mask pixel in the column. Without those, we can't read what a
   "topmost-qualifying-run" picker would have chosen on the same
   frames, so we can't validate a candidate replacement rule
   against existing data.

### Action

**Doc-and-diagnostic-only this session.** No `analyzeGate` change.
Specifically:

1. This Test G section + a §11 follow-up in `detector_hypotheses.md`
   that promotes hypothesis #1 with the lean-severity correlation
   and flags the mechanism.
2. **Non-behavioral** expansion of `[DETECT_DIAG]` logging in
   `DetectionEngine.swift` — add per-column topmost mask y, second-
   longest run, and topmost run fields to `ColStats` /
   `columnStats` / `logGateDiagPrefix`. This does not touch the
   picker; it only gives us the data we need to design the
   picker fix in the next physical test.
3. **Next physical test:** repeat the lean-variation protocol on
   front cam, ≥8 "more lean" crossings (the failing cluster), every
   crossing tapped at PF's dot position, with the user pre-labelling
   each crossing's lean severity. Then compare candidate picker
   rules (topmost qualifying run; weighted Y-centroid; etc.) against
   the new expanded-DIAG data and pick the one that best matches
   PF across all severities.

See `detector_hypotheses.md` §11 for the updated hypothesis ranking.

---

## Run 2026-04-07 Test H — back-cam lean variations + backward-lean discriminator, PF-anchored marks

> ## ⚠️ CORRECTION ADDED 2026-04-07 — READ BEFORE THE REST OF THIS SECTION ⚠️
>
> **Photo Finish does not display a dot.** PF's UI shows only a
> vertical line (the gate / measurement line). When the user tapped
> our thumbnail "where PF marked" during the post-run review, the
> tap carries only **X-axis** information (where the line is). The
> **Y** of the tap is wherever the user's finger landed near the
> line — pure finger-placement noise, not PF's Y choice. PF does
> not expose a Y coordinate anywhere in its UI.
>
> **Invalidated as quantitative claims** (struck through below in
> place — the original numbers are kept visible as a record of the
> mistake but should NOT be read as data):
> - The USER_MARK Δy table — every `Δy = our_detY − PF_dotY` number
>   is finger-placement noise on the Y axis.
> - The "Forward-lean cluster Δy ≈ −85 ± 22" cluster statistic.
> - The "PF Y values cluster mean 167, SD ≈ 6" observation.
> - DETECT_DIAG excerpt comments of the form "PF=N" / "PF placed its
>   dot at y=N" / "Δy=−N" (the underlying `[DETECT]` and
>   `[DETECT_DIAG]` log lines themselves are real data and unchanged).
> - Observation #3 (PF Y tight cluster).
> - Observation #5 (Test G #7 anomaly — there is no anomaly because
>   there is no PF Y).
> - Observation #4 (lap 7 small clipped blob) is **reframed** below
>   to drop the "3 px above tmY" claim while keeping the still-valid
>   "PF detected this clipped blob" finding.
>
> **Still valid in this section:**
> - The 9-crossing run table (detector outputs only — no PF Y values
>   in it).
> - The raw `[DETECT]` and `[DETECT_DIAG]` log lines (real data).
> - The qualitative cross-camera reproduction of the forward-lean
>   failure.
> - The qualitative backward-lean discriminator finding (lap 5
>   verbal "PF picked stomach" categorical anatomical observation).
> - The Mechanism note.
>
> **Forward-pointer:** see `detector_hypotheses.md` §12 (corrected)
> for the rebased framing and the new **§12.5** finding that *PF's
> rule is temporal* ("PF waits for the upper part of the moving
> blob to cross the gate column before firing"), and **§12.7** for
> the vertical-stick test that will discriminate the remaining
> open question (relative-to-blob vs relative-to-frame).
>
> **Memory reference:** the PF-no-dot fact is also saved as the
> feedback memory `feedback_pf_no_dot_only_x_line.md` so it
> persists across sessions.

> **⚠️ USER_MARK SEMANTICS — INVALIDATED, see correction banner above ⚠️**
>
> The original semantics note (preserved here for historical record)
> read: marks are **PF dot positions on our thumbnail**, NOT
> anatomical truth; `Δy = our_detY − PF_dotY`; negative = our picker
> is **below** PF's dot. This framing is wrong: PF does not place a
> dot. Treat all "PF dot Y" / Δy / "PF Y cluster" content in this
> section as struck through.

**Camera caveat:** This run was captured on the **back camera**. Test G
was the **front camera**. Test H is therefore the **first cross-camera
replication** of the forward-lean failure mode — important because
prior to Test H we did not know whether the failure was front-cam-
specific or a property of the picker.

**Cold-start artifact disclaimer:** the source log
(`/Users/sondre/Downloads/test lean .rtf`) contains 3 sessions and 4
total `[SESSION] detection started` markers. **Only run #2 of session
3 is real Test H data.** The earlier session/runs are exposure-flap
cold-start artifacts (full-frame 180×320 blobs from the auto-exposure
settling at boot, plus a 1-crossing run that produced unusable data
because the runner was a partial-frame edge artifact). Those are
discarded for analysis purposes and not tabulated below.

### Run setup

- 9 real-body gate crossings, single runner, single test session
  (session 3, run #2 in the source log).
- iPhone, **back camera**, manual exposure cap 4.00 ms (auto-exposure
  capped), gate column 90, build same as `307b689` + the §11.5 `/all=`
  instrumentation. **No picker change** since Test G — same algorithm
  binary.
- User pre-labelled each crossing's lean type before tapping the
  thumbnails:
  1. lean
  2. no lean
  3. lean lots
  4. lean decent
  5. **backward lean, stomach-first** ("same as PH" per user note)
  6. **backward lean** (user's verbal label said "detected wrong" but
     the Δy=0 result suggests the user self-corrected during the
     3-tap re-mark sequence — see USER_MARK section below)
  7. lots of lean
  8. lots of lean (less than #7)
  9. very minimal lean
- Of 9 crossings, 6 received PF-anchored taps (laps 1, 3, 4, 6, 7, 8).
  Laps 2, 5, 9 were not tapped (the user's verbal note for lap 5 is
  the only ground-truth signal for that crossing).
- The user explained the backward-lean rationale verbatim: *"i did the
  bvackwards lean to compare since the backwarsd lean make the lower
  part of the body lead which confimrs that photo finish biases top
  of frame"*. This is the §11.4 working model's directional prediction
  being deliberately tested.

### Detector results — full 9-crossing run table

All 9 blobs gate=YES, all met heightFraction/widthFraction/run prefilters.

| # | label | frame | t (s) | dir | blob WxH | comp y | fill | hR | wR | detY |
|---|-------|-------|-------|-----|----------|--------|------|------|------|------|------|
| 1 | lean | 104 | 3.410 | L>R | 143×238 | 82..319 | 0.28 | 0.74 | 0.79 | 220 |
| 2 | no lean | 266 | 8.823 | L>R | 103×247 | 73..319 | 0.35 | 0.77 | 0.57 | 172 |
| 3 | lean lots | 381 | 12.651 | R>L | 156×221 | 99..319 | 0.28 | 0.69 | 0.87 | 251 |
| 4 | lean decent | 475 | 15.788 | L>R | 147×240 | 80..319 | 0.32 | 0.75 | 0.82 | 282 |
| 5 | back-lean stomach 1st | 588 | 19.548 | L>R | 118×251 | 69..319 | 0.28 | 0.78 | 0.66 | 269 |
| 6 | back-lean | 696 | 23.150 | R>L | 125×251 | 69..319 | 0.30 | 0.78 | 0.69 | 163 |
| 7 | lots of lean | 1216 | 40.478 | R>L | 94×170 | 150..319 | 0.30 | 0.53 | 0.52 | 256 |
| 8 | lots of lean (<#7) | 1310 | 43.632 | L>R | 145×235 | 85..319 | 0.27 | 0.73 | 0.81 | 256 |
| 9 | very minimal lean | 1496 | 49.833 | L>R | 114×250 | 70..319 | 0.33 | 0.78 | 0.63 | 149 |

### ~~USER_MARK Δy table — stratified by lean type~~ **[INVALIDATED — see correction banner at top of section. PF does not display a dot; the "PFY" column is finger-tap noise on the Y axis.]**

> ~~`Δy = our_detY − PF_dotY` (negative = our picker is **below** PF's dot, i.e. deeper into the legs).~~
>
> ~~`PF % from blob top = (PF_dotY − comp.minY) / comp.height` — where PF landed within the blob, expressed as a fraction of blob height. 0% = top of blob, 100% = bottom of blob.~~
>
> ~~| # | type | detY | PFY | **Δy** | PF % from blob top |~~
> ~~|---|------|------|-----|--------|--------------------|~~
> ~~| 1 | forward lean | 220 | 164 | **−56** | 35% |~~
> ~~| 3 | forward lean (lots) | 251 | 174 | **−77** | 34% |~~
> ~~| 4 | forward lean (decent) | 282 | 170 | **−112** | 38% |~~
> ~~| 8 | forward lean (lots) | 256 | 158 | **−98** | 31% |~~
> ~~| 7 | forward lean (lots, small clipped blob) | 256 | 172 | **−84** | 13% |~~
> ~~| 6 | **backward lean** | 163 | 163 | **+0** | 38% |~~
> ~~| 2 | no lean | 172 | (unmarked) | — | — |~~
> ~~| 5 | back-lean stomach 1st | 269 | (unmarked, user verbal: PF picked stomach) | — | — |~~
> ~~| 9 | very minimal lean | 149 | (unmarked) | — | — |~~
>
> ~~**Lap 6 was tapped 3 times in the post-run review.** First tap recorded `Δy=+10` (userY=173), then two corrections both gave `Δy=+0` (userY=163). Use the corrected mark.~~ *(The 3-tap pattern is now reinterpreted as the user adjusting where their finger landed on the vertical line, not as the picker matching a PF dot. The Δy=0 is finger-placement noise, not a coincidence.)*
>
> ~~**`[USER_MARK]` log lines are emitted in tap order, not lap order**~~ (the user tapped them out of order during post-run review; raw lines: 980, 992, 998, 1006-1008, 1022, 1033 in the source log). *(Tap-order observation is still factually true; only the Y-axis interpretation of the taps is invalid.)*
>
> ~~**Forward-lean cluster (5 marks):** Δy ∈ {−56, −77, −112, −84, −98}, **mean ≈ −85, SD ≈ 22**. Statistically indistinguishable from the Test G "more lean" cluster (Δy ∈ {−76, −78, −71, −86, −123}, mean ≈ −87, SD ≈ 21).~~ *(The Δy values are invalid as PF-relative measurements. The qualitative cross-camera reproduction of the forward-lean failure is still valid — see Observations and `detector_hypotheses.md` §12.1 for the reframed version using observable signals only.)*
>
> ~~**PF Y values across the 6 marked crossings:** {164, 174, 170, 163, 172, 158}. **Mean = 167, range = 16, SD ≈ 6.** Striking tightness relative to the variation in blob position, blob size, and lean severity across the 6 crossings.~~ *(These are finger-tap Y values around PF's vertical line, not PF Y choices. The "tightness" is the dispersion of the user's finger placement, not a property of PF's picker. See `feedback_pf_no_dot_only_x_line.md`.)*

### High-signal DETECT_DIAG excerpts (with `/all=` per-row data)

These are the 8 high-signal frames. The `/all=` field is the §11.5
expansion landing — first time we have full per-row mask runs on
real-body lean failures. Each excerpt is preceded by a 1-line context
header.

```
#1  ~~PF=164~~  lean  comp y=82..319  blob 143x238
[DETECT] blob=143x238 hR=0.74 wR=0.79 fill=0.28 run=65 dir=L>R cands=1 area=9695 detY=220 frame=104 time=3.410
[DETECT_DIAG] frame=104 blob=143x238 need=59 avg=65 cols=[
  c88:lng=56@177..232/tot=127/runs=10/maxGap=7/tmY=141/top=24@141..164/2nd=24@141..164/all=141..164,169..169,177..232,234..252,254..254,256..256,259..259,261..261,268..269,273..293
  c89:lng=69@181..249/tot=126/runs=6/maxGap=16/tmY=141/top=24@141..164/2nd=27@268..294/all=141..164,181..249,251..253,260..261,263..263,268..294
  >c90:lng=69@185..253/tot=120/runs=3/maxGap=23/tmY=142/top=20@142..161/2nd=31@266..296/all=142..161,185..253,266..296
  >c91:lng=64@188..251/tot=118/runs=5/maxGap=26/tmY=144/top=18@144..161/2nd=25@275..299/all=144..161,188..251,253..254,264..272,275..299
  >c92:lng=64@191..254/tot=111/runs=8/maxGap=15/tmY=144/top=16@144..159/2nd=21@280..300/all=144..159,161..161,175..175,191..254,267..272,276..276,278..278,280..300 ]
  → /all= shows every column has a short top run (16-24 px) at
    y≈141-164 (the upper torso) plus a much longer run (56-69 px)
    at y≈177-254 (the leg stripe). The picker locks onto the leg
    stripe and lands at detY=220. ~~PF placed its dot at y=164 —
    inside the short top run.~~ This is the canonical "leg-fire on
    forward lean" failure with full per-row evidence — the upper-
    body mask region (y≈141-164) is present in `/all=` but the
    picker chooses the longer leg run instead.
```

```
#3  ~~PF=174~~  lean lots  comp y=99..319  blob 156x221
[DETECT] blob=156x221 hR=0.69 wR=0.87 fill=0.28 run=55 dir=R>L cands=1 area=9561 detY=251 frame=381 time=12.651
[DETECT_DIAG] frame=381 blob=156x221 need=55 avg=55 cols=[
  >c88:lng=60@224..283/tot=118/runs=8/maxGap=25/tmY=127/top=5@127..131/2nd=33@286..318/all=127..131,134..134,159..161,187..190,192..201,205..206,224..283,286..318
  >c89:lng=58@224..281/tot=111/runs=9/maxGap=25/tmY=128/top=2@128..129/2nd=30@290..319/all=128..129,131..131,134..134,160..160,185..185,189..190,194..208,224..281,290..319
  >c90:lng=49@224..272/tot=110/runs=9/maxGap=25/tmY=128/top=4@128..131/2nd=28@292..319/all=128..131,134..134,160..162,188..192,195..209,224..272,275..278,280..280,292..319
  c91:lng=49@224..272/tot=108/runs=11/maxGap=27/tmY=129/top=3@129..131/2nd=28@292..319/all=129..131,133..133,161..161,163..163,184..184,188..188,190..193,196..210,224..272,276..279,292..319
  c92:lng=49@218..266/tot=108/runs=10/maxGap=27/tmY=131/top=4@131..134/2nd=27@293..319/all=131..134,162..163,185..185,193..193,197..215,218..266,268..269,274..275,278..278,293..319 ]
  → top runs are tiny (2-5 px). Mid-blob runs of length 15-19 exist
    at y≈194-215 (mid-torso), but they're shorter than the leg run
    at y≈218-283. Picker locks onto leg, detY=251. ~~PF=174 sits in
    the gap between the top tmY=127-131 and the mid-torso runs.~~
    The qualitative finding (picker locked onto leg run, upper-body
    mask region exists but is fragmented) is the only valid read.
```

```
#4  ~~PF=170~~  lean decent  comp y=80..319  blob 147x240
[DETECT] blob=147x240 hR=0.75 wR=0.82 fill=0.32 run=74 dir=L>R cands=1 area=11186 detY=282 frame=475 time=15.788
[DETECT_DIAG] frame=475 blob=147x240 need=60 avg=74 cols=[
  c88:lng=79@241..319/tot=115/runs=6/maxGap=31/tmY=118/top=4@118..121/2nd=29@187..215/all=118..121,126..126,158..158,185..185,187..215,241..319
  c89:lng=78@242..319/tot=117/runs=6/maxGap=28/tmY=118/top=4@118..121/2nd=31@183..213/all=118..121,126..126,129..129,158..159,183..213,242..319
  >c90:lng=75@245..319/tot=114/runs=8/maxGap=45/tmY=118/top=2@118..119/2nd=30@183..212/all=118..119,122..122,126..126,128..129,175..175,178..179,183..212,245..319
  >c91:lng=75@245..319/tot=115/runs=9/maxGap=34/tmY=118/top=1@118..118/2nd=29@182..210/all=118..118,122..122,129..129,156..156,159..161,175..175,177..179,182..210,245..319
  >c92:lng=74@246..319/tot=115/runs=10/maxGap=35/tmY=118/top=1@118..118/2nd=30@181..210/all=118..118,129..130,132..132,158..158,160..161,173..173,175..175,177..178,181..210,246..319 ]
  → tmY=118 (top of mass) but the top "run" is only 1-4 px, then
    there's a 29-31 px torso stripe at y≈181-213, then the leg
    stripe of 74-79 px at y≈241-319 (literally going to the bottom
    of the frame). detY=282 = leg stripe midpoint. ~~PF=170 sits in
    the torso stripe. **Worst Δy of the run at −112.**~~ The
    upper-body mask region (the 29-31 px torso stripe at
    y≈181-213) exists but is shorter than the leg stripe — the
    canonical leg-fire failure with the longest detY excursion
    of the run.
```

```
#5  unmarked, but user noted PF picked stomach  back-lean stomach 1st  comp y=69..319  blob 118x251
[DETECT] blob=118x251 hR=0.78 wR=0.66 fill=0.28 run=100 dir=L>R cands=1 area=8413 detY=269 frame=588 time=19.548
[DETECT_DIAG] frame=588 blob=118x251 need=62 avg=100 cols=[
  c88:lng=75@245..319/tot=173/runs=16/maxGap=13/tmY=79/top=41@79..119/2nd=41@79..119/all=79..119,133..141,150..150,152..153,155..155,162..177,181..184,198..198,205..207,212..212,214..222,226..226,232..232,234..234,237..243,245..319
  c89:lng=75@245..319/tot=183/runs=14/maxGap=12/tmY=79/top=42@79..120/2nd=42@79..120/all=79..120,131..143,148..152,160..168,170..174,176..177,181..185,198..199,205..205,215..229,231..231,235..238,240..243,245..319
  >c90:lng=105@215..319/tot=194/runs=11/maxGap=11/tmY=78/top=43@78..120/2nd=43@78..120/all=78..120,127..142,146..152,159..164,167..174,177..178,181..184,190..190,197..197,203..203,215..319
  >c91:lng=103@217..319/tot=212/runs=11/maxGap=14/tmY=78/top=63@78..140/2nd=63@78..140/all=78..140,142..146,148..152,154..154,156..161,164..178,181..185,192..194,196..197,212..215,217..319
  >c92:lng=93@227..319/tot=204/runs=7/maxGap=18/tmY=78/top=62@78..139/2nd=62@78..139/all=78..139,148..159,161..179,182..185,193..197,216..224,227..319 ]
  → on a backward lean the stomach/upper body is at y≈78-140 (the
    runner is rotated backward, head BEHIND in time). The leading
    edge of motion through the gate is the lower body / pelvis at
    y≈215-319. The longest runs (93-105 px) are in that lower-body
    leading-edge region → picker locks there → detY=269. **The user
    verbally noted that PF placed its vertical line on the stomach**
    — i.e. PF anchored to the upper portion of the body, NOT to the
    temporal leading edge of motion. This is a categorical
    anatomical observation (PF's line intersected the stomach), not
    a pixel-Y measurement, and it is the strongest single
    discriminator data point in the run. Consistent with §11.4's
    "top of frame bias" and with §12.5's refined "PF waits for the
    upper part of the moving blob to cross" rule.
```

```
#6  ~~PF=163~~  back-lean  comp y=69..319  blob 125x251  ~~← Δy=+0, picker matched PF by coincidence~~
[DETECT] blob=125x251 hR=0.78 wR=0.69 fill=0.30 run=78 dir=R>L cands=1 area=9282 detY=163 frame=696 time=23.150
[DETECT_DIAG] frame=696 blob=125x251 need=62 avg=78 cols=[
  >c88:lng=81@112..192/tot=156/runs=3/maxGap=47/tmY=75/top=36@75..110/2nd=39@240..278/all=75..110,112..192,240..278
  >c89:lng=62@74..135/tot=177/runs=6/maxGap=8/tmY=74/top=62@74..135/2nd=43@144..186/all=74..135,144..186,195..223,227..227,234..234,238..278
  >c90:lng=92@186..277/tot=186/runs=5/maxGap=13/tmY=74/top=60@74..133/2nd=60@74..133/all=74..133,147..147,151..182,186..277,279..279
  c91:lng=96@182..277/tot=190/runs=9/maxGap=6/tmY=73/top=23@73..95/2nd=33@102..134/all=73..95,102..134,139..139,141..142,144..144,146..149,152..179,182..277,279..280
  c92:lng=94@179..272/tot=182/runs=8/maxGap=6/tmY=74/top=16@74..89/2nd=27@151..177/all=74..89,96..103,105..130,132..133,136..142,145..146,151..177,179..272 ]
  → c88 longest = 81@112..192 (upper body). c89 longest = 62@74..135
    (very top). c90 longest = 92@186..277 (legs). c91/c92 longest
    in legs. The picker's 3-column sliding average happened to win
    on the c88-c89-c90 window where the mid value is c89's mid=104.5
    — average = (152+104.5+231.5)/3 ≈ 163. ~~**By coincidence the
    picker landed at PF's exact Y on this frame.**~~ The picker
    landed in the upper-body band on this one backward-lean frame
    only because two of three columns had their longest run in the
    upper torso. A small change in body geometry would flip c89 to
    also pick the leg stripe, and the picker would then drop to
    the legs like all the other lean cases. Lap 6 is a lucky
    accident, not a fix. (Whether this Y also coincided with where
    PF's vertical line intersected the body is an open question
    that USER_MARK Y cannot answer — see correction banner.)
```

```
#7  ~~PF=172~~  lots of lean (small clipped blob)  comp y=150..319  blob 94x170
[DETECT] blob=94x170 hR=0.53 wR=0.52 fill=0.30 run=42 dir=R>L cands=1 area=4771 detY=256 frame=1216 time=40.478
[DETECT_DIAG] frame=1216 blob=94x170 need=42 avg=42 cols=[
  >c88:lng=53@267..319/tot=102/runs=5/maxGap=38/tmY=175/top=1@175..175/2nd=43@218..260/all=175..175,214..215,218..260,262..264,267..319
  >c89:lng=36@219..254/tot=96/runs=8/maxGap=38/tmY=175/top=1@175..175/2nd=19@281..299/all=175..175,214..216,219..254,256..259,265..273,275..279,281..299,301..319
  >c90:lng=37@220..256/tot=87/runs=11/maxGap=39/tmY=175/top=1@175..175/2nd=18@302..319/all=175..175,215..217,220..256,258..260,265..268,271..271,273..273,276..276,279..283,287..299,302..319
  c91:lng=28@219..246/tot=70/runs=11/maxGap=37/tmY=175/top=4@175..178/2nd=17@303..319/all=175..178,216..217,219..246,249..251,255..255,258..258,268..268,272..272,286..286,288..298,303..319
  c92:lng=23@218..240/tot=66/runs=12/maxGap=36/tmY=176/top=6@176..181/2nd=16@304..319/all=176..181,218..240,245..247,250..250,255..255,258..258,267..267,269..269,281..281,288..298,302..302,304..319 ]
  → Small clipped blob (94x170, comp.minY=150). The runner is
    partly out of the gate band — only the legs/pelvis are in the
    gate columns at the trigger frame. tmY=175-176 is the topmost
    visible mask pixel. ~~PF=172, just 3 px ABOVE tmY. This means
    PF placed its dot above the topmost visible mask pixel — PF
    is anchored to something larger than the gate-band mask
    (likely the full thumbnail body region, not the per-frame
    mask runs). PF % from blob top = 13% — outlier~~ **PF still
    fired and placed a vertical line on this clipped crossing**
    — confirming PF detects partial / clipped blobs and that
    PF's rule does not require the upper body to be present in
    the gate-band mask. We cannot say where on the visible blob
    PF's anchor landed because PF does not expose Y; only that
    PF fired. (See §12.5 — the small clipped blob is consistent
    with the temporal "wait for upper part of blob to cross"
    rule because the visible blob's upper part is what PF tracks,
    not an absolute frame-Y reference.)
```

```
#8  ~~PF=158~~  lots of lean  comp y=85..319  blob 145x235
[DETECT] blob=145x235 hR=0.73 wR=0.81 fill=0.27 run=103 dir=L>R cands=1 area=9061 detY=256 frame=1310 time=43.632
[DETECT_DIAG] frame=1310 blob=145x235 need=58 avg=103 cols=[
  c88:lng=101@210..310/tot=106/runs=4/maxGap=51/tmY=124/top=3@124..126/2nd=3@124..126/all=124..126,129..129,158..158,210..310
  c89:lng=102@208..309/tot=106/runs=3/maxGap=78/tmY=123/top=3@123..125/2nd=3@123..125/all=123..125,129..129,208..309
  >c90:lng=103@206..308/tot=104/runs=2/maxGap=81/tmY=124/top=1@124..124/2nd=1@124..124/all=124..124,206..308
  >c91:lng=103@205..307/tot=108/runs=4/maxGap=46/tmY=122/top=2@122..123/2nd=2@122..123/all=122..123,125..125,157..158,205..307
  >c92:lng=104@203..306/tot=108/runs=4/maxGap=45/tmY=122/top=2@122..123/2nd=2@122..123/all=122..123,125..125,157..157,203..306 ]
  → Extreme case: every column is essentially a single 100+ px
    leg stripe at y≈203-310 plus 1-3 px of upper-body noise at
    y≈122-126. tmY=122-124, but the only runs of any meaningful
    length are the legs. Picker has nothing else to lock onto.
    detY=256. ~~PF=158 → Δy=−98. PF dot lands inside the 1-3 px
    upper-body fragment.~~ Even in this extreme case (essentially
    no upper-body mask in the gate columns) PF still fired and
    placed a vertical line on the upper body — verbal observation
    only, no pixel-Y measurement possible.
```

```
#9  unmarked  very minimal lean  comp y=70..319  blob 114x250
[DETECT] blob=114x250 hR=0.78 wR=0.63 fill=0.33 run=64 dir=L>R cands=1 area=9365 detY=149 frame=1496 time=49.833
[DETECT_DIAG] frame=1496 blob=114x250 need=62 avg=64 cols=[
  >c88:lng=68@117..184/tot=88/runs=6/maxGap=15/tmY=73/top=1@73..73/2nd=9@93..101/all=73..73,76..76,79..81,86..91,93..101,117..184
  >c89:lng=65@118..182/tot=89/runs=5/maxGap=8/tmY=75/top=3@75..77/2nd=18@83..100/all=75..77,79..79,83..100,109..110,118..182
  >c90:lng=61@118..178/tot=85/runs=7/maxGap=7/tmY=73/top=1@73..73/2nd=9@92..100/all=73..73,78..80,84..90,92..100,108..108,110..112,118..178
  c91:lng=46@130..175/tot=82/runs=8/maxGap=8/tmY=72/top=3@72..74/2nd=11@118..128/all=72..74,77..80,83..89,91..99,108..108,112..112,118..128,130..175
  c92:lng=41@132..172/tot=80/runs=9/maxGap=9/tmY=72/top=3@72..74/2nd=13@76..88/all=72..74,77..80,83..89,91..99,102..106,108..108,118..127,132..172 ]
  → "very minimal lean" — the longest runs in c88-c90 are 61-68 px
    at y≈117-184 (upper torso). The picker lands at detY=149 (top
    of these runs). detY % from blob top = (149-70)/250 = 32%.
    Consistent with the cluster of marked crossings (31-38% from
    blob top). Sanity-checks the "tight cluster" observation
    even on an unmarked crossing.
```

### Mechanism

Identical to the §11 / Test G mechanism. The picker takes the longest
contiguous vertical mask run in each gate column and averages run
midpoints across a sliding 3-column window. On a forward lean the
gate column slices through the leg/pelvis region as a single tall
contiguous stripe while the torso fragments into shorter runs
separated by gaps (arm/chest/shoulder gaps after rotation). The
longest run flips from torso to leg, and the picker midpoint moves
from upper-body to lower-body. PF, empirically, stays near the upper
body regardless. **Test H confirms this mechanism is camera-
independent** — the same failure on a different camera with the same
qualitative DETECT_DIAG signature (large gaps between fragmented
torso runs and dominant continuous leg runs).

For the **backward lean** (lap 5/6), the leading edge of motion
through the gate is the lower body, but PF still placed its dot in
the upper body. This was the §11.4 working-model prediction for what
a backward lean should show, and Test H is the first time that
prediction was tested directly. The lap 6 Δy=0 result is a coincidence
(the c89 column happened to have its longest run in the upper torso,
which dragged the 3-column sliding average up); the lap 5 detY=269 +
verbal "PF picked stomach" note is the cleaner data point.

### Observations

1. **Forward-lean failure reproduces cleanly on back cam.** Across
   the 5 forward-lean Test H crossings (laps 1, 3, 4, 7, 8) our
   detY consistently lands deep in the legs (mid-200s) while the
   per-row `/all=` mask data shows shorter upper-body runs at
   y≈120-180 that the picker is missing. The same qualitative
   failure mechanism reproduces on the front camera (Test G "more
   lean" cluster, n=5). Per the user's 2026-04-07 assertion that
   PF behaves the same on front and back cam, **the failure is a
   property of the picker and is not modulated by which camera is
   in use**. ~~Numerical Δy values previously reported here
   (−85 ± 22 for Test H, −87 ± 21 for Test G) are invalid as
   PF-relative measurements per the correction banner; the
   qualitative reproduction stands.~~
2. **Backward-lean discriminator confirms top-of-frame bias.** Lap
   5 — backward lean, lower body leads through the gate in time —
   our detY=269 (legs), and the user verbally noted PF placed its
   vertical line on the stomach (upper body, the *temporal trailing
   edge*). This is a categorical anatomical observation, not a
   pixel-Y measurement, and it is the cleanest single discriminator
   for §11.4's "anchored to frame Y top, not to temporal leading
   edge" prediction. Lap 6 (also a backward lean) showed our
   picker landing at detY=163 in the upper torso by coincidence
   from a 3-column sliding average win — see lap 6 DETECT_DIAG
   excerpt above. Together laps 5 and 6 are the second independent
   geometry that confirms the working model. The lap 5 verbal
   anatomical observation also directly motivates the new §12.5
   refinement: PF's rule is **temporal** ("PF waits for the upper
   part of the moving blob to cross the gate column before
   firing"), not just spatial.
3. ~~**PF Y values cluster tightly in this run.** Mean = 167, range = 16, SD ≈ 6 across 6 marked crossings spanning forward leans, backward lean, and one small clipped blob.~~ **[INVALIDATED — PF does not display a dot. The 6 "PF Y" values are finger-tap Y dispersion around PF's vertical line, not a property of PF's picker. See correction banner at top of section and `feedback_pf_no_dot_only_x_line.md`.]**
4. **Lap 7 small clipped blob (reframed).** The runner was clipped
   at the gate column (94×170 visible blob, comp.minY=150 — only
   legs+pelvis visible in the gate band at trigger frame). **PF
   still fired and placed a vertical line on this crossing**,
   confirming PF detects clipped/partial runners and that PF's rule
   does not require an absolute "frame Y must be above N" floor
   — PF works on small blobs deep in the lower half of the frame
   too. ~~PF still placed its dot near the topmost visible mass —
   only 3 px above tmY. This reinforces "PF anchors to the topmost
   mass region" but also suggests PF's reference is the full
   thumbnail body region, not just the per-frame gate-band mask.~~
   We cannot say where on the visible blob PF's anchor landed
   because PF does not expose Y; only that PF fired. (This is
   relevant to the §12.5 / §12.7 relative-vs-absolute question
   — lap 7 is consistent with the relative-to-blob hypothesis A
   but does not falsify the hybrid hypothesis C.)
5. ~~**Test G #7 anomaly remains the open question.** Test G #7 was the only no-lean upright crossing in either run with PF strikingly far from the cluster center (PF Y = 219, 55% from blob top).~~ **[INVALIDATED — there is no anomaly because there is no PF Y. The "PF Y = 219" was a finger-tap that happened to land lower on PF's vertical line during the post-run review. The single most important open question is no longer the Test G #7 outlier; it is the §12.5 relative-vs-absolute question, which the §12.7 vertical-stick test will discriminate.]**

### Action

**Doc-only this session, per user decision** (the ship-vs-hold
question was answered with "Doc-only, run targeted test next").
No `analyzeGate` change. No parameter change. No instrumentation
change (the §11.5 expansion is sufficient for the analytical work
— Test H confirms the `/all=` field is what we needed and shows
no further instrumentation is required).

The next physical test is specified in `detector_hypotheses.md`
**§12.7** — a **vertical-stick object test** designed to
discriminate the relative-to-blob vs relative-to-frame ambiguity
in §12.5's new "PF waits for the upper part of the moving blob to
cross the gate column before firing" finding. ~~A targeted
"no-lean upright at varying camera distance" test designed to
confirm or falsify the Test G #7 pattern.~~ The previous next-test
plan (varying camera distance to reproduce the Test G #7 outlier)
is invalid because the Test G #7 outlier itself was finger-tap
noise, not a PF Y anomaly.

See `detector_hypotheses.md` §12 (corrected) for the full
hypothesis follow-up: §12.1 cross-camera replication (qualitative,
no PF Y), §12.2 backward-lean discriminator, §12.3 Y bias is real
even though PF Y is not observable, §12.4 hard-cap proposal
rejected, **§12.5 the new temporal "PF waits for upper part of
blob to cross" finding**, §12.6 doc-only changes, §12.7
vertical-stick test design.

---

## Run 2026-04-07 Test I — sensitivity tuning (frameBiasCap=0.55, localSupportFraction=0.20, minFillRatio=0.22)

**Device / setup:** iPhone, front camera, handheld. Gate column = center
(x=90 in process coords).

**Build:** commit `9953368` (frame-Y bias cap at 0.55) + lowered
`localSupportFraction` from 0.25 → 0.20 and `minFillRatio` from
0.25 → 0.22. Goal: test whether lower thresholds make detection fire
earlier on lean crossings.

**Crossings #1 and #2 are excluded** (user instruction — likely setup/
calibration crossings). Analysis covers crossings #3–#10.

### Detection table (crossings #3–#10)

| # | frame | blob | fill | run | need | detY | rawDetY | cap? | dir |
|---|-------|------|------|-----|------|------|---------|------|-----|
| 3 | 201 | 131×223 | 0.32 | 45 | 44 | 168 | 168 | no | L>R |
| 4 | 293 | 64×187 | 0.27 | 49 | 37 | 173 | 173 | no | R>L |
| 5 | 383 | 135×255 | 0.32 | 74 | 51 | 176 | 283 | yes | L>R |
| 6 | 476 | 140×249 | 0.32 | 52 | 49 | 176 | 287 | yes | R>L |
| 7 | 554 | 102×252 | 0.23 | 63 | 50 | 176 | 270 | yes | R>L |
| 8 | 629 | 141×213 | 0.23 | 45 | 42 | 176 | 189 | yes | R>L |
| 9 | 718 | 85×304 | 0.23 | 87 | 60 | 139 | 139 | no | L>R |
| 10 | 797 | 65×255 | 0.31 | 93 | 51 | 176 | 178 | yes | L>R |

### USER_MARK table (crossings #3–#10)

| # | detY | userY | Δy | userX |
|---|------|-------|----|-------|
| 3 | 168 | 166 | -2 | 86 |
| 4 | 173 | 173 | 0 | 90 |
| 5 | 176 | 164 | -12 | 94 |
| 6 | 176 | 169 | -7 | 99 |
| 7 | 176 | 146 | -30 | 144 |
| 8 | 176 | 174 | -2 | 80 |
| 9 | 139 | 129 | -10 | 89 |
| 10 | 176 | 154 | -22 | 82 |

Note: USER_MARK Y is finger-tap noise (PF shows only a vertical
line, not a dot). Δy is included for directional signal only — the
consistent negative direction across 8/8 crossings suggests our dot
is consistently below PF's line, which is consistent with late
detection (body has moved further past gate before we fire).

### Rejection patterns before each crossing

| # | local_support rejects | fill_ratio rejects | total frames delayed |
|---|---|---|---|
| 3 | 2 (run=17-18 vs need=45) | 2 (0.20, 0.21) | ~4 |
| 4 | 2 (run=3, 30 vs need=37) | 3 (0.16-0.22) | ~5 |
| 5 | **6** (run=2→19→28→24→31→34 vs need=51-52) | 0 | **6** |
| 6 | 2 (run=18, 39 vs need=25-49) | 4 (0.17-0.21) | ~6 |
| 7 | **4** (run=10→44→23→35 vs need=48-50) | 2 (0.18-0.19) | **6+** |
| 8 | 2 (run=5, 39 vs need=44-45) | 1 (0.22 — float edge) | ~3 |
| 9 | 2 (run=4, 47 vs need=56-58) | 1 (0.20) | ~3 |
| 10 | 2 (run=19, 27 vs need=49-50) | 1 (0.21) | ~3 |

### Notable DETECT_DIAG excerpts

**Crossing #5 (frame 383, lean):** rawDetY=283, cap→176. Blob 135×255
with need=51. Six local_support rejections (frames 377-382) as the
leading edge gradually built up at the gate. The run values
2→19→28→24→31→34 show the torso progressively arriving but falling
short of the 51px threshold each frame.

**Crossing #7 (frame 554, lean):** rawDetY=270, cap→176. Frame 549
near-miss: run=44 vs need=49 — would have fired with
localSupportFraction=0.15 (need=37). Four frames of local_support
rejection plus two fill_ratio rejections.

**Crossing #9 (frame 718):** detY=139, cap not active. Blob 85×304
(very tall, narrow). Need=60 at 0.20 fraction. Frame 716 near-miss:
run=47 vs need=58. With 0.15 fraction, need=45, and run=47 would
pass → 2 frames earlier.

### Observations

1. **Frame-Y bias cap working mechanically:** 5/8 crossings had cap
   fire (rawDetY 178-287, all clamped to 176).
2. **Crossings #3 and #4 (no cap) show excellent accuracy:** Δy = -2
   and 0. When the detector naturally picks the upper body, it
   matches PF well.
3. **Detection still fires late on lean crossings:** 3-6 frames of
   local_support rejections before crossings #5, #7. The 0.20
   threshold helped but didn't eliminate the delay.
4. **Fill ratio at 0.22 still borderline:** Several rejections at
   0.20-0.21, and one float-edge case at 0.22/0.22 (frame 628).
5. **Crossing #2 (excluded) was a false detection:** blob=180×320
   (entire frame), fill=0.95 — caused by a 17-frame drop making
   the whole frame register as motion. Not related to threshold
   tuning.

### Action

Lowered `localSupportFraction` 0.20 → 0.15 and `minFillRatio`
0.22 → 0.20 for the next test. Expected effect: crossings like #5
and #7 should fire 2-5 frames earlier. Arms are unlikely to false-
trigger because the 3-column sliding window averages out thin
appendages.

---

## Run 2026-04-07 Test J — head-detection regression (localSupportFraction=0.15, minFillRatio=0.20)

**Device / setup:** iPhone, front camera, handheld. Gate column = center
(x=90 in process coords).

**Build:** commit `8003aca` — `localSupportFraction` 0.15,
`minFillRatio` 0.20, `frameBiasCap` 0.55. Also includes
`gateOccupied` guard against double-triggers.

**Two sessions recorded.** First session (5 crossings) was a quick
warmup/test — excluded. Second session (15 crossings) is the main
data. Crossings #14 and #15 appear to be artifacts (#14 blob=180×320
fill=0.86 = entire frame; #15 fired immediately after at detY=201).

### Detection table (second session, crossings #1–#13)

| # | frame | blob | fill | run | need | detY | rawDetY | cap? | dir | head? |
|---|-------|------|------|-----|------|------|---------|------|-----|-------|
| 1 | 216 | 180×167 | 0.32 | 25 | 25 | 176 | 239 | yes | L>R | |
| 2 | 360 | 164×209 | 0.28 | 36 | 31 | 176 | 229 | yes | R>L | |
| 3 | 527 | 79×125 | 0.54 | 81 | 25 | 176 | 182 | yes | R>L | |
| 4 | 617 | 100×170 | 0.30 | 27 | 25 | 125 | 125 | no | L>R | **YES** |
| 5 | 713 | 175×198 | 0.36 | 39 | 29 | 176 | 238 | yes | R>L | |
| 6 | 804 | 110×245 | 0.40 | 46 | 36 | 103 | 103 | no | L>R | **YES** |
| 7 | 900 | 147×231 | 0.27 | 34 | 34 | 115 | 115 | no | R>L | **YES** |
| 8 | 1022 | 161×217 | 0.25 | 36 | 32 | 163 | 163 | no | L>R | |
| 9 | 1177 | 114×195 | 0.33 | 34 | 29 | 176 | 238 | yes | R>L | |
| 10 | 1286 | 142×306 | 0.34 | 46 | 45 | 176 | 296 | yes | L>R | |
| 11 | 1369 | 109×154 | 0.29 | 28 | 25 | 84 | 84 | no | R>L | **YES** |
| 12 | 1448 | 172×234 | 0.27 | 67 | 35 | 176 | 279 | yes | R>L | |
| 13 | 1563 | 127×229 | 0.42 | 36 | 34 | 176 | 183 | yes | L>R | |

### USER_MARK table (marked crossings only)

| # | detY | userY | Δy | userX | head? |
|---|------|-------|----|-------|-------|
| 2 | 176 | 165 | -11 | 83 | |
| 4 | 125 | 175 | +50 | 36 | **YES** |
| 6 | 103 | 152 | +49 | 56 | **YES** |
| 7 | 115 | 151 | +36 | 121 | **YES** |
| 9 | 176 | 136 | -40 | 112 | |
| 11 | 84 | 137 | +53 | 97 | **YES** |
| 12 | 176 | 148 | -28 | 125 | |
| 13 | 176 | 158 | -18 | 15 | |

Note: USER_MARK Y is finger-tap noise (PF shows only a vertical
line), but the SIGN of Δy is strongly diagnostic here. Head
detections show large positive Δy (+36 to +53) — our dot is far
above the user's tap. Non-head crossings show negative Δy (-11 to
-40) — our dot is below the user's tap.

### Rejection patterns before head-detection crossings

| # | local_support rejects before | pattern |
|---|---|---|
| 4 | 0 — fired on first qualifying frame | blob 100×170, need=25, run=27. Barely over threshold. |
| 6 | 1 frame (run=1 need=36 at frame 803) | Fired next frame with run=46. |
| 7 | 3 frames (895: run=24/need=25, 896: run=25/need=28, 899: run=20/need=34) | Fired at frame 900 with run=34 = need exactly. |
| 11 | 3 frames (1366: run=4, 1367: run=5, 1368: run=15 vs need=34) | Fired at frame 1369 with run=28, need=25 (smaller blob). |

### Observations

1. **Head-detection regression:** 4 out of 13 crossings (#4, #6, #7,
   #11) fired on the head — detY = 84-125, well above the
   torso zone (≈150-175). All four are user-confirmed (large
   positive Δy). This did NOT happen in Test I (0.20/0.22
   thresholds).

2. **Root cause — localSupportFraction too low (0.15):** The head
   alone creates a 25-35px vertical run at the gate, which now
   passes the `need` threshold (25-34 for these blobs). At 0.20,
   need would have been 34-49 for the same blobs, which the head
   alone wouldn't reach.

3. **Cap crossings still show same pattern as Test I:** Where the cap
   fires (crossings #2, #5, #9, #10, #12, #13), Δy is negative
   (-11 to -40), consistent with our dot being below PF's line.

4. **Threshold tradeoff is clear:**
   - At 0.25/0.25 (original): fires too late, legs detected
   - At 0.20/0.22 (Test I): fires slightly late, some near-misses
   - At 0.15/0.20 (Test J): fires early enough but now catches head
   - Sweet spot is somewhere between 0.15 and 0.20 for
     localSupportFraction, or a different approach entirely.

5. **`gateOccupied` guard working:** Frame 16 shows
   `[REJECT] gate_occupied` — no double-triggers observed.

6. **Artifacts:** Crossings #14 (blob=180×320, entire frame) and
   #15 (detY=201, comp.minY safety floor override) appear to be
   frame-drop artifacts, excluded from analysis.

### Action

More testing needed to determine the right balance. Options to
explore:
- Split the difference: localSupportFraction=0.18
- Add a minimum absolute gate run (e.g. ≥30px) so the head alone
  (25px) can't qualify regardless of blob-relative threshold
- Increase `minGateHeightFraction` (currently 0.08 = 25px) to
  ~0.10 (32px) to set a higher frame-absolute floor
- Blob-height-relative approach with a floor: max(30, comp.height
  × 0.15)

No code changes in this session — need to decide approach first.

---

## Run 2026-04-07 Test K — hand swipe rejection test (localSupportFraction=0.15, minFillRatio=0.20)

**Device / setup:** iPhone, front camera, handheld. Gate column = center.
User standing behind the gate line, swiping hands in circular motion.
**Photo Finish correctly rejects all of these.** Our detector should too.

**Build:** same as Test J — commit `8003aca`, `localSupportFraction`
0.15, `minFillRatio` 0.20, `frameBiasCap` 0.55.

### Detection table (all false positives — hand swipes)

| # | frame | blob | fill | run | need | what set need | detY | rawDetY |
|---|-------|------|------|-----|------|---------------|------|---------|
| 1 | 22 | 121×209 | 0.29 | 39 | 31 | blob-rel (209×0.15) | 176 | 295 |
| 2 | 81 | 116×110 | 0.46 | 26 | 25 | frame floor (320×0.08) | 176 | 191 |
| 3 | 139 | 104×135 | 0.24 | 25 | 25 | frame floor (320×0.08) | 176 | 201 |
| 4 | 311 | 124×158 | 0.26 | 25 | 25 | frame floor (320×0.08) | 176 | 202 |

### Which filter WOULD have caught each at original thresholds (0.25/0.25)?

| # | fill vs 0.25 | need@0.25 | caught by |
|---|---|---|---|
| 1 | 0.29 pass | 52 (run=39 fails) | **local_support** |
| 2 | 0.46 pass | 27 (run=26 fails) | **local_support** |
| 3 | 0.24 fail | — | **fill_ratio** |
| 4 | 0.26 pass | 39 (run=25 fails) | **local_support** |

### Near-miss analysis

Extensive GATE_DIAG near-misses throughout the run show hand swipe
gate runs consistently in the **15-24px** range, with occasional
spikes to 25-39px. The frame-absolute floor of 25px
(`minGateHeightFraction=0.08`) rejected most frames — crossings
#2-#4 fired when the run just barely reached 25-26px.

Crossing #1 is the outlier: a circular arm sweep created a 121×209
blob with a 39px gate run. This is unusually large for a hand swipe
and required the blob-relative threshold (need=52 at 0.25) to
reject.

### Key data points for threshold tuning

Hand swipe gate run distribution (from GATE_DIAG near-misses):
- Most frames: run=15-24 (rejected by current floor=25)
- Occasional: run=25-26 (barely passed floor=25)
- Rare outlier: run=39 (large circular arm motion)

For comparison, body crossing gate runs from Test I and J:
- Torso leading edge: run=34-65 (early frames, before full body)
- Full body at gate: run=67-146

**The overlap zone is 25-39px** — hand swipes occasionally reach
this range, and early body crossings start in this range. This is
the discrimination challenge.

### Observations

1. **localSupportFraction=0.15 is too permissive.** It lets the
   blob-relative need drop below the hand swipe run range.
2. **The frame-absolute floor (25px) is doing most of the work.**
   3 of 4 false positives fired because run barely reached 25.
3. **fill_ratio=0.20 is not the main issue.** Only crossing #3
   (fill=0.24) would have been caught by fill_ratio=0.25. The
   other three pass fill_ratio at any reasonable threshold.
4. **The fix space involves two levers:**
   - Raise `minGateHeightFraction` (frame-absolute floor) from
     0.08 (25px) to 0.10+ (32px+) — kills runs of 25-31
   - Raise `localSupportFraction` back toward 0.18-0.20 — kills
     the rare large-blob outlier (run=39, blob 209px)
5. **Need more test data to calibrate:** specifically, body
   crossings at this threshold to see if a 32px floor or 0.18
   fraction delays torso detection.

### Next test needed

Run with **mixed body crossings and hand swipes in the same session**
at the current thresholds (0.15/0.20). This gives us both signal
types in one log, making it easier to see where the discrimination
boundary should be. Ideally:
- 5+ body crossings (mix of upright and lean)
- 5+ hand swipes (circular arm motion, single arm reach, etc.)
- Mark which crossings are which type afterward

---

## Run 2026-04-07 Test L — mixed hand swipes + lean body crossings, front camera

**Device / setup:** iPhone, **front camera**, handheld. Two-phase
session: hand swipes first (#1–#16), then body crossings with lean
(#17–#28). User confirmed the split: "the first runs were hand swipes
and all of the next were full body."

**Build:** commit `8003aca` — localSupportFraction=0.15, minFillRatio=0.20,
minGateHeightFraction=0.08 (floor=25px), frameBiasCap=0.55.

### Detector parameters (same as Test K)

Same build and parameter state as Test K above.

### Phase 1 — Hand swipes (#1–#16): 16 false positive detections

| # | blob | hR | wR | fill | run | need | dir | detY | rawDetY | frame | time |
|---|------|------|------|------|-----|------|-----|------|---------|-------|------|
| 1\* | 97×308 | 0.96 | 0.54 | 0.30 | 47 | 46 | R>L | 176 | 292 | 181 | 5.992 |
| 2 | 136×132 | 0.41 | 0.76 | 0.28 | 25 | 25 | L>R | 176 | 217 | 321 | 11.118 |
| 3 | 129×145 | 0.45 | 0.72 | 0.27 | 29 | 25 | L>R | 176 | 228 | 361 | 12.453 |
| 4 | 132×143 | 0.45 | 0.73 | 0.25 | 26 | 25 | L>R | 176 | 232 | 378 | 13.024 |
| 5 | 143×139 | 0.43 | 0.79 | 0.26 | 33 | 25 | L>R | 176 | 224 | 418 | 14.352 |
| 6 | 118×191 | 0.60 | 0.66 | 0.33 | 31 | 28 | L>R | 176 | 243 | 440 | 15.094 |
| 7 | 152×145 | 0.45 | 0.84 | 0.26 | 25 | 25 | L>R | 176 | 216 | 458 | 15.681 |
| 8 | 112×150 | 0.47 | 0.62 | 0.37 | 29 | 25 | L>R | 176 | 227 | 482 | 16.491 |
| 9 | 133×145 | 0.45 | 0.74 | 0.22 | 25 | 25 | L>R | 176 | 226 | 509 | 17.386 |
| 10 | 107×166 | 0.52 | 0.59 | 0.24 | 30 | 25 | L>R | 176 | 245 | 531 | 18.127 |
| 11 | 138×142 | 0.44 | 0.77 | 0.25 | 28 | 25 | L>R | 176 | 226 | 553 | 18.855 |
| 12 | 99×177 | 0.55 | 0.55 | 0.28 | 26 | 26 | L>R | 176 | 250 | 574 | 19.567 |
| 13 | 116×128 | 0.40 | 0.64 | 0.32 | 33 | 25 | L>R | 176 | 244 | 641 | 21.796 |
| 14 | 109×150 | 0.47 | 0.61 | 0.28 | 28 | 25 | L>R | 176 | 228 | 662 | 22.496 |
| 15 | 138×133 | 0.42 | 0.77 | 0.27 | 28 | 25 | L>R | 176 | 220 | 679 | 23.058 |
| 16 | 124×135 | 0.42 | 0.69 | 0.39 | 27 | 25 | L>R | 176 | 224 | 701 | 23.797 |

\* Crossing #1 is likely walk-to-position (height 308 ≈ full frame,
hR=0.96), not a deliberate hand swipe. All others (#2–#16) are
circular arm motion from behind gate.

Hand swipe summary (#2–#16):
- blob heights: 128–191 (median ≈145)
- runs: 25–33 (median ≈28)
- fill: 0.22–0.39 (median ≈0.27)
- hR: 0.40–0.60
- ALL dir=L>R, ALL detY=176 (capped)
- need=25 for 13/15, need=26–28 for 2/15 (frame floor dominates)

### Phase 2 — Body crossings with lean (#17–#28): 12 detections

| # | blob | hR | wR | fill | run | need | dir | detY | rawDetY | frame | time |
|---|------|------|------|------|-----|------|-----|------|---------|-------|------|
| 17 | 121×210 | 0.66 | 0.67 | 0.24 | 38 | 31 | L>R | 73 | 73 | 724 | 24.551 |
| 18 | 88×252 | 0.79 | 0.49 | 0.22 | 41 | 37 | L>R | 146 | 146 | 855 | 28.939 |
| 19 | 115×226 | 0.71 | 0.64 | 0.24 | 33 | 33 | R>L | 155 | 155 | 931 | 31.472 |
| 20 | 89×170 | 0.53 | 0.49 | 0.24 | 25 | 25 | L>R | 117 | 117 | 1004 | 33.895 |
| 21 | 114×239 | 0.75 | 0.63 | 0.35 | 50 | 35 | R>L | 163 | 163 | 1092 | 36.832 |
| 22 | 49×168 | 0.52 | 0.27 | 0.30 | 65 | 25 | L>R | 176 | 187 | 1174 | 39.566 |
| 23 | 156×236 | 0.74 | 0.87 | 0.21 | 45 | 35 | R>L | 176 | 264 | 1262 | 42.490 |
| 24 | 150×228 | 0.71 | 0.83 | 0.24 | 47 | 34 | L>R | 176 | 264 | 1335 | 44.916 |
| 25 | 136×245 | 0.77 | 0.76 | 0.31 | 48 | 36 | R>L | 176 | 280 | 1406 | 47.301 |
| 26 | 114×240 | 0.75 | 0.63 | 0.25 | 52 | 36 | L>R | 176 | 266 | 1465 | 49.263 |
| 27 | 49×175 | 0.55 | 0.27 | 0.34 | 68 | 26 | R>L | 176 | 255 | 1538 | 51.686 |
| 28 | 180×320 | 1.00 | 1.00 | 0.61 | 288 | 48 | L>R | 162 | 162 | 1623 | 54.865 |

Body crossing summary (#17–#28):
- blob heights: 168–320 (median ≈233)
- runs: 25–288 (median ≈47.5)
- fill: 0.21–0.61 (median ≈0.24)
- hR: 0.52–1.00 (median ≈0.73)
- Mix of L>R and R>L (alternating directions)
- detY varies: 73–176 (several uncapped)

### USER_MARK Δx (PF comparison, body crossings only)

| # | detY | userX | time |
|---|------|-------|------|
| 17 | 73 | 37 | 24.551 |
| 20 | 117 | 79 | 33.895 |
| 23 | 176 | 106 | 42.490 |
| 24 | 176 | 73 | 44.916 |

Note: USER_MARK Y values omitted per standing rule.

### Near-miss GATE_DIAG — hand swipe phase (rejected)

Many hand swipe frames were rejected at local_support. Per-column
longest runs shown (c88 through c92):

| frame | blob | need | avg | c88 | c89 | c90 | c91 | c92 | range |
|-------|------|------|-----|-----|-----|-----|-----|-----|-------|
| 258 | 121×156 | 25 | 23 | 23 | 24 | 23 | 24 | 24 | 1 |
| 278 | 92×113 | 25 | 19 | 16 | 17 | 19 | 21 | 19 | 5 |
| 279 | 71×124 | 25 | 20 | 14 | 17 | 20 | 21 | 19 | 7 |
| 281 | 118×159 | 25 | 19 | 19 | 19 | 20 | 19 | 20 | 1 |
| 282 | 136×161 | 25 | 19 | 19 | 19 | 19 | 19 | 20 | 1 |
| 296 | 146×146 | 25 | 19 | 20 | 19 | 19 | 18 | 17 | 3 |
| 297 | 139×132 | 25 | 21 | 20 | 22 | 21 | 22 | 21 | 2 |
| 298 | 117×146 | 25 | 18 | 18 | 19 | 18 | 18 | 18 | 1 |
| 320 | 113×151 | 25 | 23 | 19 | 19 | 21 | 24 | 25 | 6 |
| 336 | 147×143 | 25 | 21 | 21 | 21 | 21 | 21 | 20 | 1 |
| 360 | 117×212 | 31 | 29 | 28 | 29 | 30 | 29 | 28 | 2 |
| 400 | 111×157 | 25 | 20 | 22 | 20 | 20 | 21 | 17 | 5 |
| 401 | 121×176 | 26 | 21 | 22 | 21 | 21 | 21 | 18 | 4 |
| 416 | 158×150 | 25 | 18 | 18 | 18 | 18 | 18 | 17 | 1 |
| 417 | 153×136 | 25 | 19 | 19 | 19 | 19 | 18 | 18 | 1 |
| 457 | 163×154 | 25 | 23 | 23 | 23 | 23 | 22 | 22 | 1 |
| 595 | 156×143 | 25 | 24 | 37 | 19 | 18 | 18 | 19 | 19 |
| 606 | 136×131 | 25 | 19 | 19 | 20 | 20 | 19 | 19 | 1 |
| 613 | 127×143 | 25 | 21 | 20 | 21 | 21 | 21 | 21 | 1 |
| 616 | 143×137 | 25 | 21 | 22 | 21 | 20 | 20 | 20 | 2 |
| 626 | 144×145 | 25 | 21 | 20 | 21 | 22 | 21 | 21 | 2 |

Hand swipe GATE_DIAG column range: **1–7** (except frame 595 outlier
at 19, which had one anomalous c88=37 — likely two arms overlapping).

### Near-miss GATE_DIAG — body crossing phase (rejected)

| frame | blob | need | avg | c88 | c89 | c90 | c91 | c92 | range |
|-------|------|------|-----|-----|-----|-----|-----|-----|-------|
| 1090 | 96×240 | 36 | 31 | 23 | 24 | 26 | 30 | 38 | 15 |
| 1261 | 141×236 | 35 | 29 | 23 | 11 | 24 | 29 | 35 | 24 |
| 1332 | 103×182 | 27 | 20 | 15 | 17 | 19 | 21 | 21 | 6 |
| 1401 | 104×203 | 30 | 23 | 16 | 27 | 28 | 14 | 13 | 15 |
| 1464 | 132×235 | 35 | 33 | 36 | 33 | 30 | 25 | 24 | 12 |
| 1537 | 108×239 | 35 | 29 | 8 | 8 | 21 | 30 | 36 | 28 |

Body crossing GATE_DIAG column range: **6–28**.

### DETECT_DIAG per-column analysis — the discrimination signal

Per-column longest runs for each DETECTED crossing:

**Hand swipes (#2–#16):**

| # | c88 | c89 | c90 | c91 | c92 | range | runs/col |
|---|-----|-----|-----|-----|-----|-------|----------|
| 2 | 22 | 22 | 24 | 25 | 26 | 4 | 2,2,2,2,2 |
| 3 | 29 | 29 | 30 | 29 | 28 | 2 | 2,2,2,2,2 |
| 4 | 29 | 28 | 27 | 26 | 26 | 3 | 2,2,2,2,2 |
| 5 | 31 | 32 | 33 | 34 | 34 | 3 | 2,2,2,2,2 |
| 6 | 38 | 36 | 34 | 32 | 29 | 9 | 2,2,2,2,2 |
| 7 | 25 | 25 | 25 | 25 | 26 | 1 | 2,2,2,2,2 |
| 8 | 28 | 28 | 29 | 30 | 30 | 2 | 2,2,2,2,2 |
| 9 | 26 | 26 | 25 | 25 | 24 | 2 | 2,2,2,2,2 |
| 10 | 33 | 32 | 32 | 31 | 28 | 5 | 1,1,1,1,1 |
| 11 | 28 | 28 | 28 | 28 | 29 | 1 | 2,2,2,2,2 |
| 12 | 27 | 28 | 28 | 22 | 21 | 7 | 1,1,1,2,1 |
| 13 | 35 | 34 | 34 | 33 | 34 | 2 | 2,2,2,2,2 |
| 14 | 29 | 29 | 29 | 27 | 28 | 2 | 1,1,1,1,1 |
| 15 | 28 | 28 | 28 | 28 | 29 | 1 | 2,2,2,2,2 |
| 16 | 30 | 29 | 28 | 27 | 27 | 3 | 3,3,3,3,3 |

Hand swipe column range: **1–9** (all ≤ 9).

**Body crossings (#17–#28):**

| # | c88 | c89 | c90 | c91 | c92 | range | runs/col |
|---|-----|-----|-----|-----|-----|-------|----------|
| 17 | 43 | 42 | 40 | 38 | 38 | 5 | 4,5,3,4,3 |
| 18 | 48 | 42 | 51 | 30 | 17 | 34 | 5,5,3,7,11 |
| 19 | 14 | 19 | 40 | 42 | 41 | 28 | 10,10,7,6,5 |
| 20 | 15 | 15 | 28 | 26 | 22 | 13 | 5,2,1,2,2 |
| 21 | 37 | 47 | 66 | 69 | 73 | 36 | 7,11,12,11,7 |
| 22 | 25 | 38 | 62 | 66 | 67 | 42 | 14,8,11,8,12 |
| 23 | 42 | 40 | 53 | 53 | 44 | 13 | 6,6,7,5,4 |
| 24 | 27 | 29 | 51 | 49 | 41 | 24 | 8,8,7,5,8 |
| 25 | 17 | 23 | 28 | 48 | 69 | 52 | 6,9,7,7,5 |
| 26 | 48 | 54 | 67 | 47 | 44 | 23 | 15,14,14,16,13 |
| 27 | 65 | 68 | 72 | 44 | 84 | 40 | 4,5,5,9,6 |
| 28 | 267 | 268 | 306 | 261 | 297 | 45 | 2,2,1,3,3 |

Body crossing column range: **5–52** (11/12 are ≥ 13; only #17 at 5).

### Key finding: column-run consistency discriminates hand swipes from body

The **range of per-column longest runs** (max − min across the 5
gate columns) is the strongest discriminator found:

| metric | hand swipes (#2–#16) | body crossings (#17–#28) |
|--------|---------------------|-------------------------|
| column range | 1–9 | 5–52 (11/12 ≥ 13) |
| median range | 2 | 28 |
| overlap | only #17 at range=5 overlaps |

**Why it works:** hand swipes produce uniform vertical motion across
all gate columns — the arm sweeps horizontally and covers all columns
equally. Body crossings produce uneven coverage — one side of the body
enters the gate first, so outer columns see more motion than inner
columns. This asymmetry is inherent to body geometry.

A threshold of **column range ≥ 10** would:
- Correctly reject all 15 hand swipes (ranges 1–9)
- Correctly pass 11/12 body crossings (ranges 13–52)
- Misclassify only #17 (range=5) — but #17 has run=38, which is
  above all hand swipe runs (max 33), so a combined check works

The rejected GATE_DIAG frames confirm this pattern:
- Hand swipe near-misses: column range 1–7 (consistent)
- Body crossing near-misses: column range 6–28 (variable)

### Other discrimination features (weaker)

| feature | hand swipes | body crossings | overlap |
|---------|-------------|----------------|---------|
| blob height | 128–191 | 168–320 | 168–191 |
| hR | 0.40–0.60 | 0.52–1.00 | 0.52–0.60 |
| run | 25–33 | 25–288 | 25–33 |
| fill | 0.22–0.39 | 0.21–0.61 | heavy overlap |
| runs/col | mostly 1–2 | 1–16 | overlap at low end |

None of these alone cleanly separates the two groups. Column-range
consistency is the only feature with near-clean separation.

### Head detection issue on body crossings

Two body crossings fired on the head (detY far above torso):

| # | detY | rawDetY | USER_MARK Δy | note |
|---|------|---------|--------------|------|
| 17 | 73 | 73 | +72 | head area, first lean crossing |
| 20 | 117 | 117 | +42 | upper torso / shoulder area |

This continues the head-detection regression seen in Test J. The
frameBiasCap (0.55 = Y≤176) only prevents firing too LOW — it
doesn't prevent firing on the head when the leading edge is at the
top of the frame.

### Crossing #20 barely passed

Crossing #20: blob=89×170, fill=0.24, run=25, need=25. Passed at
exact floor (25=25). Raising the floor to 32+ (minGateHeightFraction=
0.10) would have rejected this real body crossing.

---

## Run 2026-04-07 Test M — varied hand swipes only, front camera

**Device / setup:** iPhone, **front camera**, handheld. Hand swipes
only — varied types: circular, single-arm reach, both-arms, fast
flicks, etc. No body crossings in this session. PF rejection status
not confirmed.

**Build:** commit `8003aca` + buildup/colRange logging (uncommitted).
localSupportFraction=0.15, minFillRatio=0.20, minGateHeightFraction=
0.08 (floor=25px), frameBiasCap=0.55.

### Detection results — 30 false positive hand swipe detections

| # | blob | hR | wR | fill | run | need | dir | detY | rawDetY | buildup |
|---|------|------|------|------|-----|------|-----|------|---------|---------|
| 1 | 95×147 | 0.46 | 0.53 | 0.44 | 43 | 25 | R>L | 155 | 155 | 1 |
| 2 | 144×120 | 0.38 | 0.80 | 0.22 | 31 | 25 | L>R | 139 | 139 | 1 |
| 3 | 117×136 | 0.43 | 0.65 | 0.25 | 30 | 25 | L>R | 176 | 219 | 2 |
| 4 | 159×144 | 0.45 | 0.88 | 0.21 | 36 | 25 | L>R | 146 | 146 | 1 |
| 5 | 141×151 | 0.47 | 0.78 | 0.23 | 25 | 25 | L>R | 154 | 154 | 1 |
| 6 | 80×108 | 0.34 | 0.44 | 0.43 | 57 | 25 | R>L | 168 | 168 | 2 |
| 7 | 106×129 | 0.40 | 0.59 | 0.34 | 26 | 25 | R>L | 176 | 208 | 1 |
| 8 | 107×145 | 0.45 | 0.59 | 0.27 | 25 | 25 | R>L | 176 | 200 | 2 |
| 9 | 93×116 | 0.36 | 0.52 | 0.25 | 26 | 25 | R>L | 113 | 113 | 1 |
| 10 | 105×112 | 0.35 | 0.58 | 0.28 | 40 | 25 | R>L | 128 | 128 | 1 |
| 11 | 58×115 | 0.36 | 0.32 | 0.42 | 35 | 25 | L>R | 40 | 40 | 1 |
| 12 | 91×183 | 0.57 | 0.51 | 0.25 | 32 | 27 | R>L | 88 | 88 | 1 |
| 13 | 107×105 | 0.33 | 0.59 | 0.24 | 47 | 25 | R>L | 142 | 142 | 1 |
| 14 | 111×177 | 0.55 | 0.62 | 0.22 | 27 | 26 | R>L | 137 | 137 | 3 |
| 15 | 129×114 | 0.36 | 0.72 | 0.33 | 25 | 25 | R>L | 176 | 196 | 2 |
| 16 | 111×144 | 0.45 | 0.62 | 0.23 | 30 | 25 | R>L | 141 | 141 | 5 |
| 17 | 120×133 | 0.42 | 0.67 | 0.37 | 28 | 25 | R>L | 176 | 200 | 2 |
| 18 | 119×144 | 0.45 | 0.66 | 0.27 | 25 | 25 | R>L | 176 | 194 | 2 |
| 19 | 138×129 | 0.40 | 0.77 | 0.29 | 25 | 25 | R>L | 176 | 212 | 1 |
| 20 | 117×118 | 0.37 | 0.65 | 0.59 | 35 | 25 | R>L | 164 | 164 | 1 |
| 21 | 133×141 | 0.44 | 0.74 | 0.44 | 44 | 25 | R>L | 154 | 154 | 1 |
| 22 | 132×112 | 0.35 | 0.73 | 0.29 | 27 | 25 | R>L | 67 | 67 | 1 |
| 23 | 152×131 | 0.41 | 0.84 | 0.27 | 31 | 25 | R>L | 71 | 71 | 1 |
| 24 | 138×164 | 0.51 | 0.77 | 0.34 | 48 | 25 | R>L | 69 | 69 | 1 |
| 25 | 93×137 | 0.43 | 0.52 | 0.26 | 27 | 25 | R>L | 27 | 27 | 1 |
| 26 | 150×132 | 0.41 | 0.83 | 0.34 | 31 | 25 | R>L | 109 | 109 | 1 |
| 27 | 158×133 | 0.42 | 0.88 | 0.30 | 39 | 25 | R>L | 81 | 81 | 1 |
| 28 | 143×121 | 0.38 | 0.79 | 0.22 | 27 | 25 | R>L | 81 | 81 | 1 |
| 29 | 150×125 | 0.39 | 0.83 | 0.34 | 31 | 25 | R>L | 68 | 68 | 1 |
| 30 | 113×113 | 0.35 | 0.63 | 0.51 | 26 | 25 | R>L | 207 | 244 | 1 |

### DETECT_DIAG colRange summary

| # | colRange | colMin | avg |
|---|----------|--------|-----|
| 1 | 5 | 41 | 43 |
| 2 | 18 | 19 | 31 |
| 3 | 22 | 23 | 30 |
| 4 | 19 | 19 | 36 |
| 5 | 16 | 15 | 25 |
| 6 | 73 | 25 | 57 |
| 7 | 6 | 23 | 26 |
| 8 | 9 | 18 | 25 |
| 9 | 35 | 14 | 26 |
| 10 | 12 | 32 | 40 |
| 11 | 18 | 26 | 35 |
| 12 | 42 | 3 | 32 |
| 13 | 8 | 41 | 47 |
| 14 | 18 | 21 | 27 |
| 15 | 8 | 18 | 25 |
| 16 | 23 | 22 | 30 |
| 17 | 2 | 26 | 28 |
| 18 | 3 | 23 | 25 |
| 19 | 1 | 25 | 25 |
| 20 | 2 | 35 | 35 |
| 21 | 2 | 42 | 44 |
| 22 | 9 | 24 | 27 |
| 23 | 9 | 30 | 31 |
| 24 | 2 | 47 | 48 |
| 25 | 12 | 19 | 27 |
| 26 | 5 | 28 | 31 |
| 27 | 21 | 26 | 39 |
| 28 | 2 | 26 | 27 |
| 29 | 4 | 29 | 31 |
| 30 | 17 | 26 | 26 |

### Key findings — column-range hypothesis INVALIDATED

Test L found hand swipe colRange=1–9, body crossing colRange=5–52,
and proposed colRange≥10 as a discriminator. **Test M disproves this.**

Varied hand swipe types produce colRange across the full range:
- colRange ≤ 9: 16/30 (53%)
- colRange 10–22: 9/30 (30%)
- colRange ≥ 23: 5/30 (17%)

The Test L finding was an artifact of one swipe style (circular arm
motion produces uniform column coverage). Single-arm reaches and
other swipe types produce highly uneven coverage, mimicking body
crossings.

### Feature distributions — no single clean discriminator

Compared to Test L body crossings (#17–#28):

| feature | hand swipes (Test M) | body crossings (Test L) | overlap |
|---------|---------------------|------------------------|---------|
| hR | 0.33–0.57 | 0.52–1.00 | 0.52–0.57 |
| blob height | 105–183 | 168–320 | 168–183 |
| run | 25–57 | 25–288 | 25–57 (full) |
| fill | 0.21–0.59 | 0.21–0.61 | near-total |
| colRange | 1–73 | 5–52 | near-total |
| buildup | 1–5 (73% at 1) | not measured yet | — |

**hR (height ratio)** has the least overlap: hand swipes max at 0.57,
body crossings start at 0.52. But 3/12 body crossings have hR ≤ 0.57
(#20=0.53, #22=0.52, #27=0.55), so an hR threshold would reject real
crossings.

**Buildup** shows 73% of hand swipes fire at buildup=1 (first frame).
Body crossing buildup was not measured in Test L (logging added after
that run). Needs a new body crossing test with buildup logging.

### What PF might be doing differently

All 30 hand swipes passed our detector. PF (presumably) rejects them.
Since no single geometric feature cleanly separates arms from early
torso, PF may use:
1. **Higher resolution** — at 1080p the horizontal width of arm vs
   torso at the gate is very different
2. **Background model** — subtracting a learned background would make
   arm blobs much smaller/sparser than frame-differencing does
3. **Temporal confirmation** — requiring N consecutive qualifying frames
   (body approaches gradually, arm spikes in 1 frame)
4. **Minimum blob height threshold higher than ours** — PF may simply
   require hR > 0.50 or similar, accepting the delayed detection

### Next test needed

Run **body crossings with lean** using the current build (with buildup
logging) to measure body crossing buildup values. If body crossings
consistently have buildup ≥ 3 while hand swipes are mostly 1, temporal
confirmation becomes viable.

---
