---
date: 2026-09-10
status: done
implements: [agent-writes-health]
tags: [healthkit, app, ui, edits, undo]
related_tasks: [agent-writes-health]
---

# The person sees what the agent changed, and can take it back

## Goal

Show the owner every Health record an agent wrote through this phone, and let
them undo one. Until now an edit landed silently: the service keeps counts and
codes by design, the phone kept only a version number, and the only trace on
screen was a line in a log behind five taps on the app's name.

## Overview

### Context

`Applier` writes an agent's items into Health and answers the service with
counts. `Outcome` carries `applied` and a list of `{item, code}` refusals and
nothing else — never a metric, never a value — so the service cannot say what
changed. The phone is therefore the only place the contents of an edit can be
kept, and it was not keeping them.

The design was settled on a canvas of four treatments. The chosen one, V4,
invents no new shapes: every element is one the app already draws, at the app's
own measurements. The chosen flow is F1 — the strip undoes a whole fresh run,
the list carries a swipe, and the one confirmation guards the destructive row on
the detail screen.

### Current State

- `Store` has `written` (id → version) and nothing about what was written.
- `HealthKitWriter.remove(id:)` already deletes what this app wrote under an id
  and answers the days it was in. Undo needs no new HealthKit work.
- `HomeView` has a brand row, a dial, a caption, a footer and a row of keys.
- `Design.swift` has `Legend`, `Panel`, `RowDivider`, `KeyButton`, and three
  button styles. It has no dark surface, though `HomeView.handoffPanel` draws
  one inline, and no destructive style, though `Palette.alarm` is documented as
  "a stopped scale, and the one row that destroys something".

### Constraints

- **A deletion cannot be undone.** The agent gives an id and nothing else, and
  the record is gone before anything could read its value. The screen says so
  rather than offering a button that fails.
- **Undo is a removal, and removals are days owed.** Taking a record out of
  Health changes the day it was in, so the day is marked and goes up again.
- **The journal must survive a re-applied edit.** A run that dies after writing
  and before answering applies the same edit again; the journal is keyed by
  (edit name, item index) so the second pass updates one row instead of adding a
  second.
- **The service learns nothing new.** The journal is local. Nothing about it
  reaches the wire.

## Definition of Done

1. A `v4.editLog` migration and a journal keyed by (edit name, item), holding
   the item's own fields, the day it touched, its state and its refusal code.
   Evidence: `deno task test`, the new store tests.
2. `Applier` writes a journal row for every item it applies, refuses or deletes,
   and for an edit it cannot open at all. Evidence: the applier tests.
3. A list screen grouped by the day the edit arrived, with a row per item in the
   V4 shape: state legend on the left, metric and value as the title, time and
   interval underneath. Evidence: `deno task screenshots`, `04-edits`.
4. A detail screen of spec lines, with the removal as an alarm row guarded by a
   confirmation. Evidence: `deno task screenshots`, `05-edit`.
5. Swiping a row undoes it. An undone row stays in the list, struck through.
   Evidence: `.swipeActions` in `EditsView`, the struck-through row in
   `04-edits`.
6. A dark strip on the home screen while a run is unseen, with one undo for the
   whole run, and a summary row above the keys once anything has ever been
   applied. Evidence: `deno task screenshots`, `02-sending`.
7. A local notification when edits land, asked for only after the first one has.
   Evidence: `grep -n "requestAuthorization" src/App/Sources/Notices.swift`.
8. `deno task check` passes and the app builds. Evidence: the command's output.

## Solution

- `EditEntry` + `v4.editLog` + store methods: record, read recent, tally, mark
  undone, and a `edits.seenAt` watermark for the strip.
- `Applier` gains a calendar and records each item as it goes.
- `Design.swift` gains `Palette.darkLegend`, `DarkPanel` and `DangerButton`.
- `EditsView.swift` holds the list, the row, the detail screen and the wording
  of every refusal code.
- `Services` gains the summary, the undo and the notification.
- `HomeView` gains the strip, the summary row and the sheet.

## Out of scope

- F2's selection mode and its consequence sheet. F1 was chosen; both of F1's
  extra elements are system-provided, F2's two are not.
- Snapshots before an edit, which are the only way a deletion becomes
  reversible. Recorded on the canvas as U6 and left for its own task.

## Result

Done on 10 Sep 2026.

- `deno task test`: 186 Deno tests, 174 Swift tests, 1 skipped, none failed.
  The new ones are `EditLogTests` (the journal and the applier's rows in it)
  and `EditWordsTests` (every sentence these screens are made of).
- `deno task check`: clean, no `error:` lines.
- The screens are pictured by the app's own offscreen mode. `--snapshot` now
  renders five screens rather than three, over a journal of one agent run
  seeded into the demonstration store: four records written, one taken back
  out, one refused, one record the agent removed. An image renderer draws a
  list, a scroll view and a navigation stack as nothing at all, so both edit
  screens have a flat mode for it, the way `ConnectContent` already did.
- Two things the pictures caught, both fixed: the agent's id was being printed
  in small capitals, which makes a case-sensitive value a lie, and the day was
  printed beside instants that had already said which day it was.
- The three screens are on the design canvas as the page "Built · in the app",
  beside the treatments they came from:
  https://claude.ai/code/artifact/f0ff2bdd-96ca-418c-8097-fb7848c7ecc1

Not done here: a full simulator walk of the whole app in both appearances. The
appearance is pinned to light, and an archive can be created only on a phone,
so these screens are pictured the way the store screenshots are.
