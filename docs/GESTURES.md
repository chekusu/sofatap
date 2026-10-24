# Gesture settings

Available in public TestFlight iPhone 1.0 (18); see the [distribution record](verification/testflight-1.0-18.md). It changes the iPhone's local gesture mapping; existing receiver protocols and pairing credentials are unchanged.

Open the gear in the touchpad header. Choose a preset, then change individual gestures. Preferences are saved locally on the iPhone, separately for computers and televisions. A preset replaces that device category's mapping, timing and scroll direction; replacing a custom configuration asks for confirmation. Restore defaults remains available even when every gesture is disabled.

## Presets

| Preset | Computer behavior |
| --- | --- |
| Sofatap | Keeps the existing left/right double-tap regions, 300 ms hold to drag and natural two-finger scrolling. |
| Trackpad habits | Double-tap either half for a left double-click; two-finger tap for a right click. |
| Press for shortcuts | Long press for a right click, tap then hold to drag, two-finger tap for Enter, three-finger tap to toggle the keyboard. |

TV presets use pointer click, focus confirmation, Back and Home where supported. They never enable desktop-only right clicks, drag, keyboard or dictation. Android receiver capability reports limit selectable actions; previously saved unsupported actions stay visible as unavailable, and the controller still checks every request. A TV pointer click and focus confirmation are distinct actions.

## Assignments

Tap gestures include single tap, left-half double tap, right-half double tap, two-finger tap and three-finger tap. Hold gestures include a stationary long press and tap-then-hold. Slides include one-finger and two-finger movement.

- Discrete gestures can trigger a supported click, double-click, Enter/confirmation, Escape/Back, keyboard toggle or dictation toggle. Home is TV-only. An action can also be unassigned.
- Only hold gestures can hold the mouse button for a drag. Lifting or cancelling releases it; there is no persistent drag lock.
- On computers, one-finger pointer movement starts after 3 points, before a hold is ruled out. A hold is cancelled only when the finger leaves the 7-point stationary tolerance or is still sliding when the hold duration ends. A finger that rolls a few points while pressing and then rests for 100 ms keeps the hold.
- Slides can move the pointer, scroll or do nothing. Natural scrolling applies to these slides. The strip inside the touchpad's right edge retains scrollbar direction.
- Unassigning a double-tap action removes that separate gesture: individual taps still perform the single-tap action. Single taps wait only when a double tap or tap-then-hold needs to be distinguished.
- Hold duration is adjustable from 200–1200 ms; the double-tap interval from 150–500 ms. A longer double-tap interval can increase single-tap latency.
- Two- and three-finger taps require a brief stationary contact (up to 250 ms). Moving any finger beyond the stationary tolerance cancels the tap, even if the centroid does not move. Multi-finger scrolling and partial finger lifts cannot turn into clicks or a drag.

The guide displays the current assignments. The practice sheet uses the production recognizer with local visual feedback only: it has no receiver callbacks, keyboard activation or microphone capture. Opening settings pauses live control. Changing mappings, targets, app activity or the view cancels pending clicks and releases an active drag through the old target before new callbacks are installed.

## Validation

Run `bash ios/scripts/test-custom-gestures.sh` for configuration, persistence, capability and gesture conflict tests. The existing `TouchGestureTests.swift` checks continue to run against the default preset. UIKit editor, live text and drag-release recording-transport tests cover integration without desktop input.

Seven physical settings and local-practice cases have passing results on a dedicated iPhone and an iPad in iPhone compatibility mode; see the [device results and limits](verification/custom-gestures-2026-10-16.md). These checks do not replace exact physical gesture timing, receiver input or household TV acceptance. Physical receiver tests must follow the Yomado isolation rules in `AGENTS.md`; the Sony and Xiaomi TV hardware acceptance remains tracked separately.
