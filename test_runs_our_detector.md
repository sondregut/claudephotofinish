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
