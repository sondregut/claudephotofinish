# Photo Finish App — Raw Test Results

**App:** Photo Finish (sprint timing iOS/Android app)
**Testing dates:** 2025-01-19 through 2026-03-17

This file primarily contains raw observations from physical testing of the Photo Finish app. However, later sections also include grouped pattern summaries and extracted facts from the developer paper, so it is no longer a purely raw log.

---

## How the App Works (Observable)

- Phone is mounted on a tripod in portrait orientation
- A vertical red line is displayed at the center of the screen (the "gate")
- When someone runs past the phone and crosses the gate line, the app records a time
- The app shows status messages: "Athlete too far", "Detection ready", or a timestamp
- The frame turns red when the phone is moved

---

## Tests 1–9 (2025-01-19)

| # | What We Did | What Happened |
|---|-------------|---------------|
| 1 | Walked slowly toward camera from 30ft | At 10ft: app shows "Athlete too far". At 7ft: app shows "Detection ready" |
| 2 | Put hand right over camera lens | Triggered detection |
| 3 | Walked as close as possible to camera | Works at any close distance, no minimum |
| 4 | Checked available orientation modes | Portrait only |
| 5 | Waved a towel through the gate at 5ft, no person | Triggered detection |
| 6 | Walked through gate with back to camera at 5ft | Triggered detection |
| 7 | One person at ~10ft walking sideways in background, another person close to camera | Background person did NOT trigger. Close person triggered. |
| 8 | One person standing at ~10ft while another runs through gate | Standing person did NOT interfere with detection |
| 9 | Waved/moved the phone around | Frame turned red, no detection triggered |

## Tests 10–15 (2025-01-23)

| # | What We Did | What Happened |
|---|-------------|---------------|
| 10 | Stood in frame but NOT near the red line, at 10ft | App shows "Athlete too far" |
| 11 | Stood in frame but NOT near the red line, at 5ft | App shows "Detection ready" |
| 12 | Crossed the gate line extremely slowly | No detection |
| 13 | Covered camera lens completely and moved the phone | Frame turned red (even with no visual input) |
| 14 | Moved phone very slowly | Frame did NOT turn red |
| 15 | Moved phone, then held it still | Frame returned to normal after 0.5-1 second |

## Tests 20–22c (2025-01-23)

| # | What We Did | What Happened |
|---|-------------|---------------|
| 20 | Crossed gate rapidly back and forth | Both directions detected |
| 22 | Extended arm ahead of body at ~5ft, crossed gate | No trigger |
| 22b | Extended arm ahead of body, very close to camera | Triggered on arm |
| 22c | Swiped hand across camera lens | Triggered on hand |

## Tests 25–36 (2025-02-24)

| # | What We Did | What Happened |
|---|-------------|---------------|
| 25 | Leaned forward with arms/legs extended, crossed gate | Detection point was at top of shoulder/chest region, not at the extended limbs |
| 26 | Crossed with stomach forward, upper body behind | Detection point was at stomach |
| 27 | Extended arm clearly ahead of chest at normal distance, crossed gate | Detection point was at upper chest, NOT the arm |
| 28 | Extended both arm AND leg ahead of torso, crossed gate | Detection point was at upper chest/torso, NOT the limbs |
| 29 | Leaned backward so stomach was ahead of chest, crossed gate | Detection point was at lower/middle stomach |
| 30 | Repeated test 29 multiple times | Usually detected lower stomach, sometimes mid-stomach — always stomach area |
| 31 | Leaned left shoulder forward, crossed gate | Detection did not fire at the very tip of the shoulder — fired once more of the body reached the gate |
| 32 | Leaned right shoulder forward, crossed gate | Same as test 31 |
| 33 | Ran with head/neck sticking far forward | Detection point was at upper torso/shoulder area, not the head |
| 34 | Twisted so shoulders were forward, hips back, crossed gate | Detection point was at the shoulder |
| 35 | Twisted so hips were forward, shoulders back, crossed gate | Detection point was at the stomach region |
| 36 | Approached gate neutrally, then threw shoulder forward one step before the line | Detection perfectly captured the forward shoulder position on that exact moment. Head crossed first but was not the detection point. |

## Tests 37–47 (2025-02-24)

| # | What We Did | What Happened |
|---|-------------|---------------|
| 37 | (A) Crossed gate super slowly. (B) Approached slowly then accelerated right at gate line. | (A) No detection. (B) Triggered. |
| 38 | Held laptop at arm's length (camera saw thin ~30cm edge), crossed gate | Detection point was at chest, not the laptop |
| 39 | Held 1.5m broomstick (~4cm thick) vertically ahead of chest, crossed gate | Detection point was at chest, not the broomstick |
| 40 | Waved towel through gate with no person present | Triggered |
| 41 | Passed laptop/board through gate with no person | Triggered only when very close to camera. Did NOT trigger at 1-3m. |
| 42 | Passed broomstick through gate with no person. Also tried towel. | Broomstick (~4cm thick): NOT detected. Towel: detected. |
| 46 | Passed broomstick through gate at varying distances, measured pixel width in app's debug view | Detected when broomstick was 131px wide in a 1628px-wide frame. Not detected when smaller. |
| 47 | Passed rectangular object through gate, measured pixels in debug view | Object was 772px tall × 373px wide in a 2456×1702 frame. Detected. |

## Tests S1–S25

| # | What We Did | What Happened |
|---|-------------|---------------|
| S1 | Placed static object at the gate line | No detection |
| S2 | Moved object very slowly through gate | No detection |
| S3 | Moved object through gate at walking speed. Object was ≥31% of total frame height. | Triggered |
| S4 | Moved object through gate at walking speed. Object was <31% of total frame height. | No detection |
| S5 | Moved object at an angle through gate at slow speed | No detection |
| S6 | Waved arm at running speed through gate | No detection |
| S7 | Two quick passes through gate | Both detected. Minimum ~0.5s gap between detections. |
| S8 | Moved object super slowly through gate | No detection |
| S9 | Passed thin broomstick (<8% of frame width) through gate at various speeds | No detection at any speed |
| S10 | Swiped thin diagonal pencil/stick through gate at fast speed (indoors) | Triggered (object was below 31% of frame height at the gate column) |
| S11 | Swiped same diagonal pencil/stick through gate at slow speed | No detection |
| S12 | Passed two boards through gate with a vertical gap between them. Each board was <31% of frame height, but their combined top-to-bottom span was >31%. | No detection |
| S13 | Moved slowly to gate line, stopped, then moved slowly past | No detection |
| S14 | Moved slowly toward gate, then accelerated right at the gate line | Triggered |
| S15 | Placed object past the gate line, then moved it away quickly | No detection |
| S16 | Fast hand swipe across gate (low light, phone facing ceiling, ~40-50cm distance). Hand was below 31% of frame height. | Triggered |
| S17 | Slow hand swipe across gate (same low light, ceiling setup) | No detection |
| S18 | Tested in very dark and very bright conditions | Triggered in both |
| S19 | Changed lighting mid-session (turned lights on/off) | Still worked after lighting change |
| S20 | Covered lens completely, uncovered, immediately crossed gate | Triggered instantly |
| S21 | Pointed flashlight directly at camera | No false trigger |
| S22 | Wore horizontally striped shirt (alternating dark/light bands), crossed gate | Triggered |
| S23 | Swept objects of varying heights through gate at walking speed | Objects ≥30% of total frame height triggered. Smaller did not. |
| S24 | Passed two separated objects through gate. Each below 30% of frame height, but together spanning >30%. | No detection |
| S25 | Placed phone against white wall, swiped white/blank towel across in dim lighting | Triggered |

## 2026 Tests 1–15 (2026-02-25 through 2026-03-17)

**Terminology clarification for tests 8a/8b/8c/12:** "Elbow" here does **not** mean just the elbow joint. It refers to a pose where the forearm and hand are held roughly vertically in front of the body, creating a tall narrow vertical blob led by the elbow/forearm/hand assembly.

| # | What We Did | What Happened |
|---|-------------|---------------|
| 1 | Passed objects of decreasing width through gate | Objects less than 8% of frame width were not detected |
| 2 | Captured screenshots of Photo Finish's debug view | Debug view shows a bounding box around detected motion with height/width in pixels |
| 3 | Swiped thin pencil through gate | App shows "Athlete too far too small" |
| 4 | Placed stationary object on gate line | No detection |
| 5 | Person in white clothes crossed gate against white wall | Triggered |
| 6 | Runner leaned forward at steep angle so chest crossed gate. Full body in frame was tall (well over 30% of frame height), but only a small sliver of the body (~6% of frame height) was at the gate column itself. | Triggered — detection point was at the forward chest position |
| 7 | Crouched to make entire body shorter than ~25-30% of frame height, crossed gate | No detection |
| 8a | Pushed elbow through gate. Body was completely outside the frame. | Detected the elbow (when close enough to camera) |
| 8b | Same elbow push through gate. Body was visible in frame and moving. | Did NOT detect the elbow. Detection fired later when more of the body had reached the gate. |
| 8c | Same elbow push through gate. Body was visible in frame but standing completely still — only the elbow was moving. | Detected the elbow |
| 9 | Extended arm horizontally (T-pose), pushed arm through gate ahead of chest. Body was moving. | Did NOT detect the arm. Detection fired later when more of the body had reached the gate. |
| 11 | Pushed arm ahead of body through gate. Tested with body both moving and still. | When body was moving: arm not detected, detection fired on body. When body was still: arm detected. |
| 12 | Pushed tall elbow through gate while torso was also moving | Did NOT detect the elbow. Detection fired later when more of the body had reached the gate. |
| 12b | Repeated elbow test with elbows/forearms held in front of the body, creating a tall narrow vertical blob ahead of the torso. Reviewed from Photo Finish capture thumbnails across multiple repeats. | App repeatedly appeared to detect the elbow/forearm blob instead of waiting for the torso. This suggests this is a real failure mode or threshold-sensitive case, not just a one-off anomaly. |
| 12c | Crossed more sideways with face toward the camera and one hand on the hip/torso silhouette. Reviewed from Photo Finish capture thumbnails. | App appeared to reject the hand-on-hip region and still detect the torso instead. |
| 12d | Ran a similar leading-object test using a small towel in front of the body. | App appeared to reject the towel and wait for the body instead of detecting the towel. |
| 12e | Swiped a hand across the gate with the thumb clearly leading ahead of the palm. | App appeared to reject the thumb tip and detect farther back on the broader palm/hand region instead. |
| 12f | Crossed the gate with a book using a sharp corner as the leading tip, and compared it with the same book crossing with a flat edge leading at similar distance and speed. | The app did not detect the very tip of the corner. It waited until more of the book had passed the gate. With the same book held flat-edge-first, detection occurred much closer to the true leading edge. |
| 12g | Crossed the gate with a dish-soap bottle using the narrow rounded top/nozzle as the leading tip. | The app did not detect the very tip. It waited until a thicker part of the bottle had reached the gate. |
| 12h | Repeated the soap-bottle test while rotating the same bottle through different orientations, keeping speed and distance similar. | The more vertically tall/blunt the front slice looked, the closer detection moved to the true leading edge. The more diagonal/slivery the front slice looked, the farther inward the chosen point moved. The shift looked smooth rather than abrupt. |
| 13 | Extended arm horizontally so it was wide but the entire visible body was less than 30% of total frame height | No detection |
| 14 | Ran with a forward lean, head ahead of torso | Detection point was at upper torso, not the head |
| 15 | Passed a wide but vertically short object (spanning only about 10-15 pixel rows) through gate while body was also present | Did not trigger on the short object. Detection fired later when more of the body had reached the gate. |
| 15b | Tried a leg/foot-leading pose with the lower leg held vertically at the gate while the torso was not moving much | Detected the leg when the lower leg was truly vertical at the gate. If the leg was not fully vertical, it did not detect it. |

## Additional Observation (2026-03-17)

| What We Did | What Happened |
|-------------|---------------|
| Waved motion near the very top of the body's area in frame | Triggered |
| Waved motion near the very bottom of the body's area in frame | Triggered |

## Additional Observations

| What We Did | What Happened |
|-------------|---------------|
| Person stood completely still in the camera's view for 30+ seconds, then suddenly crossed the gate | Detected instantly on the first movement |
| Placed a large object (box) on the gate line, left it sitting perfectly still for a long time, then yanked it away fast | Did NOT trigger when the box was removed |
| Placed an object on the gate line and left it still until it merged into the background, then pulled it away | Did NOT fire — the app did not detect the removal of the object |
| Ran an informal forward-lean ladder from small lean to extreme finish-line lean | Small lean detected the torso very accurately at the front edge. As the lean became more extreme, the chosen point tended to move farther back inside the torso. |
| Repeated bottle/straight-edge start-position test: used a clearly-large-enough object, held it completely still just a few mm before the gate, waited briefly, then pushed it through | Fired repeatedly |
| Repeated bottle/straight-edge start-position test: used the same clearly-large-enough object, placed it already overlapping/on the gate line, paused briefly or only very shortly, then pushed it farther through or away | Did NOT fire repeatedly |
| Repeated straight-edge reset test: started the same clearly-large-enough object on the gate line, moved it slightly back off the line, then pushed it through again | Fired repeatedly |

---

## Hand/Arm Swipe Speed Tests (2026-04-05)

| # | What We Did | What Happened |
|---|-------------|---------------|
| HS1 | Swiped hand/arm across gate at fast speed | Triggered. Debug view showed bounding box: 400px wide × 114px tall in a 540×724 frame (15.7% of frame height). |
| HS2 | Swiped hand/arm across gate at slower speed | No detection |
| HS3 | Swiped a hand/arm super super fast across essentially the whole frame so the moving object should normally be large enough and wide enough | Completely invisible to the detector. No usable motion/debug box was seen. Ordinary fast crossings were still detected; the failure only appeared at the extreme end of speed. |

**Key observation:** Speed affects whether a hand swipe triggers in both directions. A moderate-fast swipe can trigger even when the debug box height is only 15.7% of frame height, ordinary fast crossings are still seen, but an insanely fast swipe can become completely invisible to the detector. This suggests there is a usable middle speed range, with misses at both the too-slow and extremely-too-fast ends.

---

## Key Behavioral Pattern: Body-Part Suppression

The following tests demonstrate a strong pattern: **when a smaller body part crosses the gate and meets size/speed thresholds, but a larger body (torso) is also moving in the frame behind it, the smaller part often does NOT trigger detection.** The app often waits for the larger body to arrive at the gate. However, later elbow/forearm-leading repeats show this pattern is not absolute.

**Tests where a smaller part was REJECTED despite meeting thresholds (larger body moving in frame):**

| Test | What crossed the gate | What was behind it | Result |
|------|----------------------|-------------------|--------|
| 8b | Elbow | Body visible and moving | Elbow rejected — detection fired later when torso arrived |
| 9 | Arm (T-pose) | Body moving | Arm rejected — detection fired later when torso arrived |
| 11 | Arm ahead of body | Body moving | Arm rejected — detected on body |
| 12 | Tall elbow | Torso also moving | Elbow rejected — detection fired later when torso arrived |
| 14 | Head (forward lean) | Torso behind | Head rejected — detected at upper torso |
| 15 | Wide but short object (~10-15px rows) | Body also present | Short object rejected — detection fired later on body |
| 33 | Head/neck (sticking far forward) | Torso behind | Head rejected — detected at upper torso/shoulder |

**Contrasting tests where the smaller part WAS detected (no larger body moving behind it):**

| Test | What crossed the gate | Body status | Result |
|------|----------------------|-------------|--------|
| 8a | Elbow | Body completely off-screen | Elbow detected |
| 8c | Elbow | Body visible but standing completely still | Elbow detected |
| 11 (still case) | Arm | Body still | Arm detected |

Updated interpretation: the app usually suppresses detections from smaller leading parts when a larger moving body follows behind, but this suppression is not perfect and can fail in some elbow/forearm-leading poses.

---

## From the App Developer's Academic Paper

**Paper:** "Assessing the Accuracy of the Photo Finish: Automatic Timing Android App" (2024)
**Authors:** Johann-Lukas Voigt, Arthur Voigt, Paulo Leite, Andreas Plewnia (Photo Finish GbR)

Observable facts stated in the paper:

| What the Paper Says | Where |
|---------------------|-------|
| Frame rate is 30 fps on all phones | Section 4.4 |
| Uses linear interpolation of frame timestamps and "distance of the chest marker from the measurement line" | Figure 10 |
| Adds 0.75 × exposure_duration to the calculated crossing time | Section 4.4 |
| "Triggers between the middle and the end of a blurred image section" | Section 4.4 |
| All camera settings are automatic (exposure, ISO, focus, shutter) | Section 4.4 |
| Contrasting color between runner and background is important | Recommendation |
| Optimal phone distance: 1.4-1.6m from track edge | FAQ |
| Portrait orientation only | FAQ |
| 75th percentile accuracy: 10ms, 95th percentile: 14-15ms | Results |
