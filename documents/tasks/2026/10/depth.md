# Depth on the shell

Opened 2026-10-07 on the owner's instruction: give the app a sense of volume.
Built on its own branch (`feat/depth`), on top of `feat/motion`.

## Goal

The shell has depth the way an iOS 26 app has depth: the controls float over
the content on Apple's own material, which catches light and answers the
finger by itself, and nothing on screen fakes either of those.

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
material has no API to soften the rim. Next step waits on the owner's choice.

## Definition of Done

- [x] First attempt rolled back, kept on `depth-attempt-1`.
- [x] Way forward, dial face, journal key and bottom keys are interactive
      Liquid Glass on iOS 26; unchanged before it.
- [x] Content (panels, strip, rows, walkthrough dial) carries no glass.
- [x] No custom shadow or motion code remains.
- [x] `deno task check` and `deno task test` pass.
- [x] Simulator walk (iOS 26.5): welcome and everyday screens, the dial still
      toggles the pause.
- [ ] The owner's look on the phone (dev copy).
- [ ] Store screenshots regenerated from this branch once it is merged — and
      by a simulator capture, since the offscreen `ImageRenderer` path may not
      draw glass.

## Verification

- `deno task check` green; `deno task test` green, 244 Swift tests passed and
  1 skipped, as before the first edit.
- Simulator, iPhone 17 Pro Max, iOS 26.5, Release build: the keys and the
  dial's face read as glass lifted off the shell with the system's soft
  shadow and bright rim; "Begin setup" is orange glass with white type; a held
  press on the dial and its release toggled the pause.
