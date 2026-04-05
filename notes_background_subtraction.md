# Research 02: Background Subtraction

Background subtraction is the main alternative to pure frame differencing. It matters because some of your tests look compatible with it, while others do not.

## What Background Subtraction Changes

Instead of comparing only the current frame to the immediately previous frame, a background model tries to remember what the scene usually looks like.

That changes behavior in important ways:

- a moving object can remain foreground even if its current pixel values are similar to the previous frame
- a stationary object can gradually be absorbed into the background
- once absorbed, removing it may or may not create a new foreground event depending on the update policy

## Main Families

### Running average / simple adaptive background

- easy to implement
- adapts quickly
- can absorb stationary objects fairly fast
- often too fragile for measurement work without extra guards

### Mixture of Gaussians (MOG / MOG2)

- standard surveillance approach
- models multiple background states per pixel
- good for flicker, waving trees, repeating motion
- more complex than a first Photo Finish clone probably needs

### Sample-based models such as ViBe

ViBe is useful for this project because it shows how a modern background model can:

- initialize from a single frame
- update conservatively
- still slowly absorb new stationary objects

That matters because your current observations include both:

- instant readiness in a new scene
- ambiguous evidence that a stationary object may have merged into the background

## Why Update Policy Matters

The hardest design question is not just "is there a background model?" It is "how does it update?"

Two extremes:

- `conservative update`: only pixels already classified as background are allowed into the model
- `blind update`: even foreground-like pixels can get written into the model over time

Practical consequence:

- conservative update keeps moving objects sharp, but can leave ghosts
- blind update adapts faster, but can absorb slow movers

ViBe explicitly discusses this tradeoff. Its update policy is conservative, but the model still evolves over time and can be initialized from one frame.

## How This Maps to Your Tests

### Compatible with background subtraction

- board/box left still on the gate, then removed, sometimes does not trigger

That is consistent with an object being absorbed into a background-like model.

### Not clean proof of background subtraction

- person stands still for 30 seconds, then sprints, and still triggers

That does not fully kill background subtraction by itself, because:

- some models update conservatively
- some models absorb static objects slowly
- a suddenly moving person can still create strong foreground even after long stillness

### Current takeaway

Background subtraction is plausible, but not required yet.

For the clone:

- start with frame differencing first
- add a background model only if the controlled board-removal tests keep demanding it

## Practical Clone Advice

If you test background subtraction later, do it behind a feature flag:

- `none`
- `running average`
- `sample based`

Then compare all three against the same board-removal and stand-still-then-sprint tests.

## Why This Research Matters to the Clone

The clone can easily go wrong in either direction:

- no background model at all may create false triggers on board removal if Photo Finish has some adaptive baseline
- too much background adaptation may absorb runners or leading objects in ways the real app does not

The evidence is not strong enough yet to lock this down, so background subtraction should stay optional in v1.

## Sources

- Barnich and Van Droogenbroeck, "ViBe: A Universal Background Subtraction Algorithm for Video Sequences": [PDF](https://orbi.uliege.be/bitstream/2268/145853/1/Barnich2011ViBe.pdf)
- Weiming Hu, Tieniu Tan, Liang Wang, Steve Maybank, "A Survey on Visual Surveillance of Object Motion and Behaviors": [PDF mirror](https://www.cs.cmu.edu/~dgovinda/pdf/recog/01310448.pdf)
