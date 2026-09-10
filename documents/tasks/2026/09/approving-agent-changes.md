---
date: 2026-09-10
status: done
implements: [agent-writes-health, agent-edits-on-screen]
tags: [healthkit, app, edits, approval, protocol]
related_tasks: [agent-edits-on-screen]
---

# An agent may add, but it may not change or remove without being asked

## Goal

A record that already stands in Health is not the agent's to overwrite or take
away on its own. Adding something new stays automatic; changing or removing
something waits for the person to say yes.

## Overview

### Context

`Applier.write(_:of:)` applies every item as it comes: a `put` is saved under
`efferent:<id>` with a climbing version, a `delete` removes what this app wrote
under that id. Nothing distinguishes the first `put` for an id from the second,
and nothing asks. The journal (`editLog`) already keeps every item's own
fields, so a held item can be applied later from the journal alone.

### What the surface already gives us, verified

- **The service accepts a second outcome for the same edit.** `server/src/
  index.ts` reads the earlier outcome to recover `bytes` and `at` when the `e/`
  object is gone, then overwrites `o/<name>`. So the phone can answer "waiting
  for the person" now and revise that answer to applied or declined later —
  no service change, and the agent reads the final word through
  `phone_data_edits`.
- **The journal holds enough to apply an item later.** `EditEntry` carries
  `recordID`, `metric`, `start`, `end`, `value`, `unit` and `stage`: exactly the
  fields of `EditItem.Put`. A held row rebuilds into the item it came from.
- **The version must not be drawn early.** `Store.nextVersion(for:)` climbs on
  every call, so a held item draws its version when it is applied, never when
  it is held.
- **"What stands in Health" is knowable.** `HealthKitWriter` already looks a
  record up by its sync identifier in `remove(id:)` and `daysHeld(metric:id:)`.
  The `written` ledger is not the right test: it keeps the row after an undo, so
  it would call a fresh `put` a modification when nothing is there any more.

### Constraints

- **Nothing may stall the queue.** An edit that is fetched and left unanswered
  is fetched again on every launch, forever, in front of the edits behind it.
  So a held item is answered at once with a word, and the item is kept here.
- **The outcome stays counts and codes.** A held item is one more word in the
  closed set — never a metric, never a value, never a day.
- **A code is a wire contract.** `OUTCOME_CODES` lives in `protocol/edits.ts`,
  the Swift `OutcomeCode`, the MCP tool description and the `setup_guide`
  Python reference. All four change together or an agent reads a word nobody
  explained.
- **The person must be able to find the question.** An edit held and never
  mentioned is worse than one applied silently: the agent is waiting, the
  person does not know, and nothing on the screen says so.

## Decided

- **The line is what stands in Health.** A `put` over a record that is in
  Health now, and a `delete` of one, wait for the person. A `put` under an id
  Health holds nothing for is an addition and lands at once; a `delete` of
  something that is not there is `notFound` as before, and bothers nobody.
- **The decision covers the whole run, and there is no per-record decision.**
  One screen shows everything waiting and carries two actions: approve them all
  or turn them all down. A record's own page says it is waiting and offers no
  button of its own.

## Definition of Done

1. Two words in the closed set — `awaitingApproval` while it waits, `declined`
   when the person says no — in `protocol/edits.ts`, the Swift `OutcomeCode`,
   the MCP tool description and the `setup_guide` reference, in one commit.
   Evidence: `deno task check`, `deno task interop`.
2. The applier holds a change or a removal instead of applying it, answers the
   service at once so the queue moves, and never draws a HealthKit version for
   an item it did not write. Evidence: `ApplierTests`.
3. The phone can revise an outcome it has already sent, and owes one until the
   service has taken it. A decision made offline is reported on the next run.
   Evidence: `ApplierTests` against the fake service.
4. One screen shows everything waiting with two actions, reached from the dark
   strip and from the list. Evidence: `deno task screenshots`.
5. A record waiting for a decision reads as waiting in the list and on its own
   page, and offers no action there. Evidence: the same screenshots.
6. A notification says how many records are waiting and names nothing.
   Evidence: `Notices.swift`.
7. `deno task check` and `deno task test` pass. Evidence: the commands.

## Solution

- `EditEntry.State` gains `waiting` and `declined`; `EditTally` counts both.
  What is waiting is read as `ever.waiting`, which is a count no watermark
  applies to — a question does not stop being a question by being looked at —
  so `EditSummary` needs no field of its own. `EditTally.total` leaves the
  waiting count out: a question is not something the agent did.
- `editLog` gains `owed`: the service has not been told what this row now says.
  A decision sets it, a report that landed clears it.
- `HealthWriter` gains `holds(id:metric:)`, which answers with the *days* the
  record is on rather than a yes: a removal names no metric and no instant, so
  its day is the only thing the screen can say about it, and this is the last
  moment anything can ask. The put path narrows to the item's own type; a
  delete scans the catalogue, as `remove` already does.
- `Applier` decides per item, and gains `tell()` (report what is owed, at the
  head of every run), `approveWaiting()` and `declineWaiting()`. The outcome for
  an edit is rebuilt from that edit's journal rows, so a revision says the whole
  truth rather than a difference. It also reads those rows *before* deciding, so
  an edit handed over twice never reopens a decision: a declined item is
  answered `declined` again, and an item this very edit already applied is
  written again without asking.
- The app: the strip becomes the ask while anything waits, a review sheet holds
  the two actions, and the list carries a lit row into it.

## Affected surface

- `protocol/edits.ts`, `src/Core/Sources/Wire/Edits.swift` — the codes.
- `src/Core/Sources/Upload/Applier.swift` — the decision per item.
- `src/Core/Sources/Health/HealthWriter.swift` — "does this record stand".
- `src/Core/Sources/Store/EditEntry.swift`, `Store.swift` — a waiting state,
  the items waiting, and rebuilding an item from its row.
- `src/App/Sources/Services.swift` — approve, decline, and the revised outcome.
- `src/App/Sources/HomeView.swift`, `EditsView.swift`, `EditWords.swift`,
  `Notices.swift`, `Snapshot.swift` — the question on the screen.
- `tools/mcp.ts`, `server/src/setup-guide.ts` — what the agent is told.
- Tests: `EditLogTests`, `EditWordsTests`, `ApplierTests`, `EditInteropTests`,
  `protocol/edits_test.ts`.
- Docs: `README.md`, `AGENTS.md`, `documents/connection.md`.

## What was built

Done and verified on 2026-09-10.

- **The wire.** `awaitingApproval` and `declined` in `OUTCOME_CODES`, the Swift
  `OutcomeCode` (now `CaseIterable`, which is what makes the wording test cover
  every code), the `phone_data_edits` description and the `setup_guide`
  reference. `deno task interop` agrees.
- **Health.** `HealthWriter.holds(id:metric:)` answers with the days a record
  under that id is on, asked of Health itself.
- **The journal.** `waiting` and `declined` states, a `v5.editLog.owed` column,
  and `waitingEdits`, `edits(of:)`, `declineWaiting`, `owedEdits`,
  `markEditTold`. `EditEntry.asItem` rebuilds a held item from its row.
- **The applier.** Holds a change or a removal, answers at once, never draws a
  version for an item it did not write, and revises the outcome after the
  decision — including one made with no network, which the next run pays.
- **The screen.** The dark strip becomes the ask while anything waits;
  `EditReviewView` shows everything waiting and carries the two actions; the
  list carries a lit row into it; a waiting record's own page says so and offers
  no button. The notice counts what is waiting and names nothing.

Evidence: `deno task check` (186 Deno tests, the app builds), `deno task test`
(190 Swift tests passed, 1 skipped, 0 failed — 16 more than before),
`deno task interop`, and `deno task screenshots`, which now renders six screens
including `06-waiting`.

One thing the screenshots do not picture: a waiting record's own page. It is
covered by `EditWordsTests` instead — the note, the "your answer" field and
`canBeUndone == false`, which is what makes that page offer nothing to press.
