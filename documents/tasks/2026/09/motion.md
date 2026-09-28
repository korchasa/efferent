# Motion on the shell

Opened 2026-09-28 on the owner's instruction: give the app the movement it
needs to feel responsive and smooth, on its own branch (`feat/motion`).

## Goal

Every change on screen that alters layout, answers a finger or makes a person
wait says so by moving, and nothing moves for decoration. One vocabulary of
movement for the whole app, so two screens making the same kind of change move
the same way.

## Overview

Before this branch the shell had one animation — the dial's arc, on an
ease-in-out curve — and every other change landed in a single frame: a step of
the walkthrough replaced the previous one outright, a key gave no sign of a
press until the finger lifted, the calendar under "A day I choose" appeared at
full size, and the dial's face swapped between "Up to date" and a figure with
no transition.

All movement now goes through `src/App/Sources/Motion.swift`. It holds four
named animations, three named transitions, one button style and the press
modifier. No screen writes a duration or a curve of its own.

### The presets

- `Motion.standard` — spring, 0.35 s, no overshoot. Layout that moves, a panel
  arriving, a step changing, a figure turning into another figure.
- `Motion.snappy` — spring, 0.2 s, no overshoot. A key under the finger, a lamp
  lighting on a row, the old dial face leaving.
- `Motion.smoothLong` — spring, 0.5 s, no overshoot. The whole screen changing
  (walkthrough to home) and the dial's scale catching up with a run.
- `Motion.fade` — ease-in-out, 0.35 s. What `standard` becomes with Reduce
  Motion on: `Motion.standard(reduced:)` picks between them.
- `Motion.pressedScale` 0.97 with a dim to 0.85 (0.6 for the quiet and danger
  keys, as before) — press feedback, applied on press by `PressableKey` and
  `.pressed(_:)`.
- `Motion.sweepPeriod` 2.4 s and `Motion.sweepTail` 12 marks — the dial's
  waiting sweep, the only loop in the app.
- `Motion.arrivalDrop` 8 pt — how far a panel or a sentence drops as it
  arrives.

Nothing bounces: no gesture on this app throws anything, so an overshoot would
read as a fault. There are no custom drag gestures either, so the gesture rules
(1:1 tracking, velocity hand-off, momentum projection) had nothing to apply to;
the sheets are the system's own and already follow them.

### The transitions

- `.step(forward:reduced:)` — a walkthrough step. Forward comes in from the
  trailing edge and leaves by the leading one; back runs the same path the
  other way. Cross-fade with Reduce Motion on.
- `.arriving(reduced:)` — something joining from just above: a short drop plus
  a fade, and the reverse on the way out.
- `.face(reduced:)` — the dial's face. The new face settles in with a 0.9 scale
  and a fade; the old one only fades, at `snappy`, so the two are never legible
  on top of each other.

## Screen by screen

- **Walkthrough to home** (`RootView`) — `smoothLong` cross-fade.
- **Walkthrough steps** (`SetupView`) — `.step`, driven by `Motion.standard(reduced:)`.
  The header stays put; its back chevron fades in and out; the step counter
  rolls with `.numericText()` at `standard`. When the direction reverses,
  `go(to:)` sets the direction first and moves on the next main-actor turn,
  because a removed view keeps the transition it had in the previous pass.
  Kept at `standard` rather than `smoothLong` although it fills most of the
  screen: the header does not move, and the step is a navigation push, which
  the platform runs at about this length.
- **Range step** (`RangePicker`) — rows are `PressableKey`; the lamp and outline
  at `snappy`; the calendar `.arriving` at `standard`; the chevron turns 90° with
  it; the line under each row fades (`.contentTransition(.opacity)`) at
  `standard` when Health's answer arrives; a selection tick
  (`.sensoryFeedback(.selection)`) when the choice moves to another row. The
  remark under the range and the problem text fade and arrive at `standard`.
- **Preparing step** — the dial sweeps while the archive is being made (`Dial`
  `waiting:`); title and blurb fade over; the queue line rolls its figure and
  arrives; Continue and Try again fade in.
- **Home** (`HomeView`) — the strips about an agent's edits `.arriving` at
  `standard`; the connect button, the journal key and the "connect agent" key
  fade; the status line and the "since" date fade at `standard`; the dial's
  face is a `PressableKey` with a light impact on start and stop, its faces
  `.face`, the figure rolling down with `.numericText(countsDown: true)`, the
  play/pause symbol `.symbolEffect(.replace)` at `snappy`; the dial sweeps while
  Health is read again; the caption under it fades at `standard`.
- **Journal** (`EditsView`) — acting on an entry reloads the list inside
  `Motion.standard(reduced:)`.
- **Every key** — `ProminentButton`, `ConnectButton`, `QuietButton`,
  `DangerButton`, `WideKeyButton`, `KeyButton`: sink and dim on press.

## Reduce Motion

Every slide, drop and scale becomes a cross-fade of the same length. Press
feedback stays, because it confirms a press rather than moving anything. The
dial's sweep stops travelling: the figure's own arc stays where it is and
breathes. Checked in the simulator on 2026-09-28 by recording the walkthrough
with Reduce Motion on: nothing crossed the screen, every step change was a
cross-fade. That walk ran on the build before the review below; the review
left the Reduce Motion branch of every transition and of the dial as it was.

Appearance has nothing to check here: the palette is pinned to light, so dark
mode draws the same pixels.

## Review as a motion designer

After the first pass the owner asked for a review of whether each movement
fits its job. Walking the recordings frame by frame found four defects, all
fixed on the branch:

- **The calendar slid down over the rows above it.** `.move(edge: .top)` moves a
  view by its own height, and the calendar is taller than the three rows over
  it. Now a short drop from its row.
- **The waiting sweep juddered and ran too fast.** It jumped a whole mark at a
  time — 37 marks a second against a 60 Hz screen, so steps of one and two
  frames alternated — and a turn took 1.6 s, which read as anxious. With the
  figure at zero it had no lit arc to move at all. Now a head with a fading
  tail that moves continuously, each mark lit by degrees, one turn in 2.4 s,
  independent of the figure.
- **The old dial face stayed readable through the new one** for about 0.3 s
  after a pause. Now it leaves at `snappy` while the new one arrives at
  `standard`.
- **The line under each range rolled every letter** when it changed from
  "Health has nothing to read yet" to a figure, unreadable for the length of
  the change. `.numericText()` is for numbers; the line now fades. The same
  change for the "since" date on home.

Left as it is:

- The sweep on the preparing step often shows for only about a second, because
  the archive is ready that fast. A brief loop is the honest picture of a brief
  wait; holding it longer would add a delay nobody asked for.
- The queue line on the preparing step keeps rolling digits: once it holds a
  count it changes as a count. Its first change, from "nothing waiting" to a
  figure, rolls the letters too.

## Found in passing, not changed

The "A day I choose" row names a default day six months back (28 Mar 2026 on
the walk), earlier than Health's first record (23 Jun 2026); the remark under
the range already clamps it to 23 Jun. That was the behaviour before this
branch.

## Verification

- `deno task check` — passes.
- `deno task test` — 227 passed, 1 skipped, 0 failed.
- Simulator walks on iPhone 17 Pro with seeded Health, against the local
  service: forward and back steps, the calendar opening and closing, the send
  starting, the dial sweeping while Health is read again, pause and resume on
  home — with Reduce Motion off and on, recorded and read frame by frame at
  20 fps.
