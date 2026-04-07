# Framerate Feasibility: 60 / 120 fps with the Current Detector

Analysis date: 2026-04-06. No code changes were made — this is a feasibility report
only. The detector currently runs at a hard-locked 30 fps (`activeVideoMin/MaxFrameDuration
= 1/30` and the 1280×720 format selector in `CameraManager.applyCameraFormat`).

The question: could the same algorithm run at 60 or 120 fps without (a) saturating
the per-frame CPU budget, (b) thermal-throttling, or (c) breaking detection?

Short answer:

- **60 fps:** technically feasible with cleanups (silence hot-path prints, eliminate
  per-frame `Data` allocs in `copyYUVPlanes`). Detection thresholds need re-tuning
  *or* the detector needs to switch to N-vs-N-2 differencing.
- **120 fps:** feasible only with additional work (vImage-based `extractGray`,
  N-vs-N-4 differencing, accept thermal limits on long sessions).
- **If the goal is timing precision, higher fps with the same algorithm is the wrong
  lever** — the position-based interpolator shrinks proportionally and gives no net
  precision gain.

---

## 1. Per-frame CPU budget

Per-frame work today (`DetectionEngine.swift` + `CameraManager.swift`), every frame
while detecting:

| Stage | Where | Approx cost on A14+ |
|---|---|---|
| `extractGray` (180×320 nearest-neighbor downsample, scalar Swift, transpose path) | DetectionEngine.swift:399-425 | ~0.4–0.8 ms |
| Diff + threshold (57,600 px, scalar Swift, unsafe ptrs) | DetectionEngine.swift:201-220 | ~0.2–0.4 ms |
| Connected components, two passes, union-find | DetectionEngine.swift:680-781 | ~0.5–1.5 ms (mask-density dependent) |
| Gate analysis (5 cols × blob height) | DetectionEngine.swift:789-882 | <0.1 ms |
| **`copyYUVPlanes` (full Y + CbCr, ~1.4 MB)** | CameraManager.swift:547-569 | **~0.6–1.2 ms + allocator pressure** |
| `print()` calls — `[COMP]`, `[GATE_DIAG]`, `[DETECT_DIAG]`, `[FRAME_DROP]` | DetectionEngine.swift:280, 944-967 + 367 + CameraManager.swift:466 | **highly variable, 0.05–2 ms each, blocks the serial queue** |

Per-frame budgets:

| | 30 fps (today) | 60 fps | 120 fps |
|---|---|---|---|
| Time per frame | 33.3 ms | 16.7 ms | 8.3 ms |
| Steady-state CV work (no prints, no detection) | ~2–3 ms | ~2–3 ms | ~2–3 ms |
| Plane-copy share | ~3 % | ~6 % | ~12 % |
| Headroom for diag prints + thumbnail dispatch | huge | modest | **none** |

The non-detection idle path is fine at any rate — `[CAM]` log fires at most ~1 Hz
and the detection pipeline is gated on `isDetecting`.

### The two real bottlenecks at higher fps

1. **`copyYUVPlanes` allocates ~1.4 MB of `Data` every frame.** At 30 fps that's
   42 MB/s; at 60 fps 84 MB/s; at 120 fps **168 MB/s** of malloc/copy churn.
   Already flagged in `pipeline_audit.md` §6.3 as the dominant per-frame cost.
   Allocator pressure also produces sporadic stalls that break the per-frame
   budget at 120 fps.
2. **`print()` on the serial processing queue.** stdio is line-buffered and
   synchronous; on the same queue that owns the AVFoundation delegate, every
   print stalls capture. Invisible at 30 fps, fatal at 120. CameraManager already
   documents this for `[FRAME_DROP]` (CameraManager.swift:404-407).

---

## 2. Thermal / power

Three independent heat sources, all of which scale with fps:

1. **Sensor + ISP.** Going 30→60 fps roughly doubles ISP work; 30→120 fps
   quadruples it. iPhones are known to thermally throttle 120 fps capture in
   continuous use after several minutes (this is why slo-mo in the Camera app
   caps recording length on hot devices). A sprint timing session that runs for
   minutes between resets is in the danger zone for sustained 120 fps.
2. **Memory bandwidth.** The plane-copy issue above is also a thermal issue —
   DRAM traffic burns power. 168 MB/s of `Data` allocations at 120 fps will warm
   the SoC noticeably more than the actual CV work.
3. **CPU.** Scalar Swift loops are not the dominant heat source even at 120 fps
   (small loops, hot in L1). vImage / SIMD `extractGray` would actually run
   *cooler* than the current scalar version.

Outdoor sun + warm device + 120 fps for a multi-minute session will likely
throttle. Cool indoor 720p120 should sustain. 60 fps has comfortable thermal
headroom.

---

## 3. Algorithmic correctness — the biggest concern

Detector parameters in `DetectionEngine.swift` are calibrated against the
**inter-frame motion at 30 fps**. Changing fps changes the geometry of the motion
mask in ways that are not just "more frames":

| Parameter | Current (30 fps) | What changes at 60/120 fps |
|---|---|---|
| `diffThreshold = 15` | Assumes ~33 ms inter-frame motion | Inter-frame motion is 1/2 (60) or 1/4 (120) → mask is much **thinner**. Same threshold may cut into the leading edge. |
| `heightFraction = 0.33` | Mask blob spans ≥33% of frame height | At 120 fps the diff strip is just leading/trailing edges; the *connected* blob may shrink vertically because the body's interior moved less than the threshold. **High risk of dropped detections.** |
| `widthFraction = 0.08` | OK at 30 fps | At 120 fps the leading-edge strip can be 1–3 px wide; this filter may still pass but `minFillRatio` won't. |
| `minFillRatio = 0.25` | Rejects sparse hand swipes | Higher fps = sparser mask in general → fill ratio drops → **valid crossings start looking like hand swipes**. |
| `localSupportFraction = 0.25` | Proportional to blob height | Self-scaling, basically OK. |
| `cooldown = 0.5 s` | Real-time | Real-time, fps-independent. |
| `warmupFrames = 10` | ~333 ms at 30 fps | ~83 ms at 120 fps — likely **too short** for AE to settle. Should be expressed in time, not frame count. |
| Position-based interpolation `dBefore` / `dAfter` | Works because diff strip is a few px wide | At 120 fps the strip may be 1–2 px wide → sub-frame fraction collapses to {0, 0.5, 1}. **You lose the precision benefit you hoped to gain from higher fps.** |

The interpolation point is the key tension: the *reason* you'd want higher fps is
finer crossing-time precision. But the existing interpolator gets its precision
from the **width of the inter-frame diff strip**, which **shrinks** at higher fps.
So switching to 120 fps with the same algorithm gives you 4× more frames but ~4×
less per-frame interpolation resolution — net no gain in timing accuracy.

The right way to exploit higher fps is **multi-frame differencing** (e.g. compare
frame N vs N-2 at 60 fps, or N vs N-4 at 120 fps) so the inter-difference window
stays ~33 ms. That keeps all of the existing thresholds valid and gives you the
benefit of higher temporal sampling for cooldown / leading-edge detection without
retuning every constant.

---

## 4. Camera plumbing changes required

Minimum mechanical changes (not implemented — listed for the report):

- `applyCameraFormat` (CameraManager.swift:159-227) hard-filters for
  `r.minFrameRate <= 30 && r.maxFrameRate >= 30`. iPhone 720p formats that
  support 60/120/240 fps are different `AVCaptureDevice.Format` instances and
  would be filtered out. Need to choose by *target fps*, not by 30.
- `device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)`
  (and Max) hard-locks to 30 fps. Would need to be parameterized.
- `maxExposureCapMs = 4.0` is fine at 60 fps (16.7 ms frame interval) and at
  120 fps (8.3 ms). At 240 fps (4.16 ms) the cap is at the limit and AE is
  forced to ISO-pump aggressively.
- 720p high-fps formats are usually `isVideoBinned = true` — slightly worse SNR
  but identical 1280×720 dimensions. The downstream pipeline doesn't care.
- `warmupFrames = 10` should become a wall-clock duration (e.g.
  `warmupSeconds = 0.33`) so AE settling time is fps-independent.

---

## 5. Recommendation

**60 fps is feasible** with three preconditions:
- (a) silence diagnostic prints in the detection hot path,
- (b) eliminate or defer `copyYUVPlanes` (e.g. only copy on the frame *after* a
  candidate, or convert it to a fixed reusable buffer pool instead of `Data`
  allocation),
- (c) accept that detection thresholds need re-tuning *or* switch to N-vs-N-2
  frame differencing so the existing thresholds keep their meaning.

**120 fps is feasible only if** you additionally:
- (d) move `extractGray` to vImage (`vImageScale_Planar8`),
- (e) run multi-frame differencing (N vs N-4) so the diff strip width is
  preserved,
- (f) accept thermal throttling on long sessions or hot environments.

**If the goal is "better timing precision," 60/120 fps with the same algorithm
is the wrong lever** — you'll spend a lot of CPU and battery and not improve
precision because the interpolator shrinks proportionally. The cheaper
improvement that gives the same precision benefit is to keep capture at 30 fps
and refine sub-pixel interpolation (e.g. weight `dBefore` / `dAfter` by mask-pixel
intensity instead of binary edges).

---

## 6. Suggested follow-up order (if/when this gets picked up)

1. **Measure first.** Add a per-frame `[BUDGET]` line printing
   extractGray + diff + CC times in microseconds for one run at 30 fps. Real
   numbers before any 60/120 budget assumption.
2. **Silence diagnostic prints inside `processFrame`** behind a flag —
   independently useful, prerequisite for any higher-fps experiment.
3. **Eliminate the per-frame `Data(bytes:count:)` allocation in `copyYUVPlanes`**
   by reusing a pool of two pre-allocated buffers. Independently useful at 30 fps
   too — addresses `pipeline_audit.md` §6.3.
4. **Then** prototype 60 fps behind a debug toggle and see if existing thresholds
   still fire on real crossings. Likely they won't, and you'll need to switch to
   N-vs-N-2 differencing.

## 7. Verification for any future implementation

Whichever changes are made, validation is the same as the rest of the project:

- Run on a physical iPhone (Simulator can't produce real frames).
- Compare crossing detection rate at 30 vs 60 (vs 120) fps for the same
  crossings, looking at `[CROSSING]` count in logs.
- Watch for `[FRAME_DROP]` and `[GAP]` lines (CameraManager.swift:404, 428).
- Watch for thermal throttling: `[CAM] exp=…` will jump if AE is being squeezed,
  and iOS will eventually drop fps silently if the device gets hot.
