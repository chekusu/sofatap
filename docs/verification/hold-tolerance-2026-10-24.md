# Hold-to-drag tolerance after early pointer motion

A Windows user reported that dragging a window occasionally failed to start. Since the 3-point desktop pointer start threshold was introduced, the iPhone and Android recognizers also cancelled the 300 ms hold as soon as the finger left that 3-point radius. A finger that rolls a few points while pressing therefore moved the pointer instead of pressing the button. Before that change, a hold tolerated the 7-point stationary tolerance.

## Behavior

- Desktop pointer movement still starts after 3 points; TV and scroll-mapped slides are unchanged.
- A hold, including tap-then-hold, is cancelled only when the finger leaves 7 points, or when it moved after the 3-point start and has not rested (within 1 point) for 100 ms at the hold deadline.
- Rest is judged at the deadline itself. Movement observed after the deadline, before a late timer or tick, cancels the hold instead of starting a drag.
- On Android, queued pointer motion is flushed before the button press, so it is not counted as drag motion.

## Checks

- Android: `GestureEngineTest` and `GestureConfigurationTest` (41 JUnit tests) pass when compiled with plain `javac` against JUnit 4.13.2 and org.json. Against the previous engine, the two settled-roll tests fail and the slow-slide and late-movement guards pass, confirming the regression and the guards.
- iPhone: new `tests/TouchGestureTests.swift` cases cover a settled roll, a slow slide inside 7 points, movement after the deadline, leaving 7 points and a settled roll on the second touch. Swift was unavailable in the authoring environment; these run in the macOS CI job.

No physical phone, receiver or Windows window drag was exercised. The change widens the hold region from 3 to 7 points for a finger that settles quickly, so a small fast nudge followed by a 300 ms rest now becomes a hold; physical gesture acceptance should confirm that trade-off.
