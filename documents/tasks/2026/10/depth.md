# Depth on the shell

Opened 2026-10-07 on the owner's instruction: give the app a sense of volume.
Built on its own branch (`feat/depth`), on top of `feat/motion`.

## Goal

The keys on the shell read as physical keys: they stand off it on a still,
soft shadow, go down under the finger with a light tap, and nothing moves
when the phone does. Content stays printed flat.

## Overview

### First attempt, rejected

Light from above drawn by hand: every key on a 3 pt lip with a cast shadow,
the dial's face a raised key in a well, panels with a resting shadow, and a
`CMMotionManager` tilt at 30 Hz moving every shadow and face gradient by a few
points. The owner tried it on the phone and called it unnatural: the shadows
sat in fixed positions and visibly switched between them. Two reasons, both in
the method rather than the numbers: the offsets were recomputed in discrete
samples on the main thread, a new position every other frame of a 60 Hz screen
with nothing interpolating between them; and the whole thing imitated what the
system already renders properly. It was rolled back; the commit survives on
the branch `depth-attempt-1` (`fa8bb91`).

### Second attempt: Apple's own layers

Apple's guidance (HIG *Materials*, "Applying Liquid Glass to custom views")
puts depth in layering: Liquid Glass is "a distinct functional layer for
controls and navigation elements" that floats above the content layer; glass
is not to be used in the content layer, and on custom controls "sparingly",
for "the most important functional elements". The material blurs and bends
what is under it, reflects light, and "reacts to touch and pointer
interactions in real time" when made `interactive()`. So:

- **Glass** (iOS 26+, `keyGlass` in `Design.swift`): the way forward
  (`ProminentButton`, `ConnectButton`, tinted with the brand orange), the
  dial's face on the everyday screen (`DialKey`, a glass disc), the wide
  journal key and the row of keys along the bottom. All interactive; their
  own press feedback replaces the shared sink-and-dim (`keyPressed`), so no
  key answers twice. The bottom keys share one `GlassEffectContainer`
  (`glassLayer`), spacing 4 pt under their 8 pt gap so they never merge.
- **No glass**: panels, the dark strip, the range rows, the journal, the
  walkthrough's dial — all content. They stay printed on the shell.
- **No hand-made light**: no custom shadow, highlight, gradient or motion
  sensor anywhere. What the glass does with light and motion is the system's,
  and so are Reduce Transparency, Increase Contrast and Reduce Motion.
- **Before iOS 26** the keys keep their old look exactly: white panel with a
  hairline, or the orange fill, and the shared press feedback.

### Owner's verdict on the second attempt

Tried on the phone the same day and called unnatural again: a white outline
around every key. Confirmed in the simulator capture — across the dial's edge
the shell reads 235, the glass rim 249–253, the face 247. The cause is where
the glass sits, not how it is tuned: Liquid Glass shows itself by bending what
is under it, and these keys sit on a flat, pale, motionless shell, so there is
nothing to bend and the only visible trait left is the rim highlight. Apple
puts glass over content that moves under it (bars over scrolling lists,
sheets over a screen); Efferent's sheets already get that from the system. The
material has no API to soften the rim.

### Third attempt: raised keys on a still shadow

The owner asked how Apple and leading apps do it, and chose the tactile path.
Apple keeps in-content buttons flat (`bordered`, `borderedProminent`) and puts
glass on floating layers; apps built on a physical-key feel — (Not Boring),
and the five Max Rudberg reviews in "Sometimes a button just wants to look
like a button" (2025-10-30) — lift a key with a diffuse shadow, a slight
gradient and a clear press with a haptic. So (`keyCap` in `Design.swift`):

- Light from straight above, fixed: a tight contact shadow (black 14 %,
  radius 1) and a soft one under it (black 8 %, radius 10, 5 pt down). No
  hairline on a raised key — the shadow is its edge; with the hairline as
  well it read as an outline again, and its own shadow fell inside the key.
- Face: white to #FAF9F7 top to bottom; the way forward runs #FF6331 →
  accent → #F04711. Fixed shades, because `Color.mix` needs iOS 18.
- Press: the cap drops 1.5 pt and both shadows close up (`Motion.snappy`);
  the legend under a bottom key stays put. The key's style passes the press
  down through the environment (`keyIsDown`), so the cap goes down even when
  it is only part of the button's label.
- Haptic: a light impact as the key lands (`keyDown`). The dial has none of
  its own — the screen already taps once when sending starts or stops.
- Same on every iOS version; no glass, no motion sensor.

### One rule for every element

After the raised keys the owner asked how they sit with the rest of the app,
chose latched keys for the range rows, and asked for every other element to
be checked — the black notice about an agent's edits read as foreign. The rule
the shell now follows: what is pressed is a raised key; a word that acts is a
text button, flat, as in Apple's own apps; what is read is printed flat, with
a hairline or a rule.

- **Range rows** (`RangePicker`, setup step and the reach-back sheet):
  `LatchedKey` — raised, the chosen one stays down. A key that is down is one
  even tone a shade darker (`KeyLight.panelDown`) with its shadow closed up; a
  face shaded at the top was tried first and the owner found it unnatural. The
  ink outline is gone; the lamp stays.
  No haptic of their own — the list already ticks on a change.
- **Agent-edits notice** (home, both variants): a white `Panel` with a
  hairline and an orange lamp, like the walkthrough's device remarks. Its two
  ways on are text buttons under a rule — "see what changed" (it used to be
  the whole dark slab that opened the journal) and "take it all back".
- **The prompt in the connect sheet**: a white `Panel` with mono type, as the
  log prints its lines. `DarkPanel` and `Palette.darkLegend` are gone.
- **A disabled key** (the log's send key on an empty log): lies flat and
  fades instead of standing up looking pressable.
- Left as they are, on purpose: quiet and danger text buttons, the back
  chevron, info panels and notes, spec rows, the journal list, the edit page,
  the walkthrough's dial (it is not pressed), the calendar. System surfaces —
  toolbar buttons (iOS 26 glass pills, which sit over the sheet's content and
  read as one more raised key), alerts, swipe actions, the share sheet, the
  Health sheet and lock-screen notices — are drawn by iOS and keep its look.

### The dial sat high

On the phone the owner saw the dial above the middle. Not a depth change: the
dial and the room reserved for its words (22 + 34 pt) were centred as one
block, so the dial itself sat 28 pt above the middle of the space between the
brand row and the footer. The same height is now kept empty above the dial, as
a frame that gives way before the spacers do, so a short phone still never
pushes the words into the footer.

Then the owner chose the centre of the screen instead of the centre of that
room. `ScreenCentred` (a `Layout` in `HomeView.swift`) puts the dial's centre
at the middle of the whole screen, safe areas included, and moves it off that
line only as far as it must to stay clear of the top and of the keys. Its first
version placed the dial's block from the left edge, and the block is narrower
than the screen, so the dial sat to the left; it is centred across now.

## Definition of Done

- [x] First attempt rolled back, kept on `depth-attempt-1`.
- [x] Second attempt (Liquid Glass keys) replaced: no glass anywhere.
- [x] Way forward, dial face, journal key and bottom keys are raised on a
      still shadow, drop on press, and tap once as they land.
- [x] Content (panels, strip, rows, walkthrough dial) stays flat.
- [x] No motion-sensor code.
- [x] Range rows are latched keys; the notice and the prompt are printed
      panels; no dark surface remains; a disabled key lies flat.
- [x] `deno task check` and `deno task test` pass.
- [x] Simulator walk (iOS 26.5): welcome and everyday screens, the dial still
      toggles the pause.
- [x] The owner's look on the phone (dev copy): accepted 2026-10-07, dial
      centred.
- [ ] Store screenshots regenerated from this branch once it is merged (the
      offscreen render draws these shadows, so `deno task screenshots`
      serves).

## Verification

- `deno task check` green; `deno task test` green, 244 Swift tests passed and
  1 skipped, as before the first edit.
- Simulator, iPhone 17 Pro Max, iOS 26.5, Release build, third attempt:
  offscreen renders of the welcome, everyday and connect screens show the
  keys and the dial's face lifted on a soft shadow with no outline; a live
  held press on "Reach back" dropped the cap with a tighter shadow while its
  legend stayed in place. `deno task test`: 244 passed, 1 skipped, 0 failed.
- Same simulator, element pass: offscreen renders of the everyday screen
  (new notice) and the connect sheet (white prompt panel); live in the
  reach-back sheet, choosing "Last 30 days" latched it and raised the old
  choice, "A day I choose" latched and opened the calendar. The simulator
  seemed to drop taps, and the sheet closed twice: both times a second tap
  aimed at the "reach back" key landed on the sheet's own "Reach back to here"
  button, which sits at the same spot. Left alone for 20 s the sheet stays. The disabled key was
  not seen on screen. `deno task test`: 244 passed, 1 skipped, 0 failed.
- Dial position, offscreen render of the everyday screen (1290×2796 px): the
  dial's centre within 2 px of the middle of the room between the notice and
  the footer. `deno task test`: 244 passed, 1 skipped, 0 failed.
- Screen centre, live on iPhone 17 Pro Max (iOS 26.5, Release, `--demo`, notice
  shown): the ring spans rows 1038–1829 of 2868, centre 1433.5 against 1434;
  across, its right edge and radius put the centre at 659.5 of 1320. `deno
  task test`: 244 passed, 1 skipped, 0 failed.
