# One word per operation: who did it, and what happened to the record

Opened 2026-09-20 on the owner's instruction, after the TestFlight run raised the
question by accident: the journal showed one row reading `undone` and another
reading `deleted`, and the two words looked like alternatives when they are not.

The owner's ruling, in their words: removing a record is **one operation**
whether the person or the agent does it, it is called a removal everywhere, and
it is the same operation at every level of the app. The TestFlight run stops
until this ships, and everything is re-tested on the build that carries it.

## What is actually wrong

Today one column carries two different facts at once. `applied` and `deleted`
say what the **agent** did. `undone` says what the **person** did, and hides what
actually happened to the record — undoing an addition removes it, while undoing a
removal or a replacement writes a record back. So a reader cannot answer either
question reliably, and the two words sit in the same place on the row.

A literal reading of "call it all a removal" cannot work: it would have the app
call a restoration a removal. What the ruling means, unpacked, is that the app
has exactly **two** operations against Health — **write** and **remove** — and
each one has somebody who asked for it. Undo is not a third operation; it is the
person performing one of the two.

## The target

Two fields instead of one.

- **What happened to the record**: `written` (a record stands because of this
  row), `removed` (it was taken out), `refused` (Health never took it; `code`
  says why). `waiting` and `declined` stay untouched — nothing produces them any
  more, they belong to the approval gate that was removed, and the rule that a
  decision an older build recorded is never reopened still holds.
- **Who asked**: the agent, or the person.

Then the four cases read as one verb set:

- agent added → agent · written
- agent removed → agent · removed
- person reversed an addition → person · removed
- person reversed a removal or a replacement → person · written

## Migrating the journal, which is the only copy there is

`editLog` holds the only record of what an agent did — the service is told counts
and codes and nothing else — so the migration must lose nothing. Every existing
row maps without guessing, because the row already carries the evidence:

- `applied` → written, agent
- `deleted` → removed, agent
- `refused` → refused, agent
- `waiting`, `declined` → unchanged, agent
- `undone` → person, and what happened is read off the row:
  - `metric` is null — the item was a removal, so the undo wrote the record back
    → written
  - `metric` present, `displaced` empty — a pure addition, so the undo removed it
    → removed
  - `metric` present, `displaced` non-empty — a replacement, so the undo wrote the
    displaced record back → written

A test has to build a database holding one row of every old state and assert the
mapping, because this is the one step where a mistake costs data.

## The surface

Eight files of code: `EditEntry`, `Store`, `Database` (a v8 migration),
`Applier`, `Services`, `EditWords`, `EditsView`, `Snapshot`. Four test files:
`ApplierTests`, `EditLogTests`, `EditWordsTests`, `HealthWriterTests`. Plus
`documents/design.md` and `documents/requirements.md`.

**Outside this repository**, in the hub: the store screenshots `04-edits.png` and
`05-edit.png` are the journal and an edit's page, rendered from this app's own
offscreen mode. New wording means re-rendering and re-uploading them, which is
store-visible and needs its own go-ahead.

## Decided by the owner, 2026-09-20

1. **A row reads as a verb and the one who acted**: `Agent wrote`, `Agent
   removed`, `You removed`, `You wrote it back`. One verb set, whoever acted.
2. **The key says the operation it will perform**: `Remove the record` when
   reversing an addition or a replacement, `Write the record back` when
   reversing a removal. It changes per row because the consequence does.
3. **The notice uses the same two verbs**, and a mixed run lists both:
   `2 records written`, `1 record removed`, `2 written, 1 removed`. Still counts
   only — no metric, no value, no day.
4. `undoneAt` is renamed, because the ruling is that the vocabulary is the same
   at every level.

## Nothing left open

The last question — whether the swipe in the list should ask as the key on a
record's page does — was answered by the owner on 2026-09-20: it stays as it is.
A swipe is a gesture aimed at one row, the key is the end of reading about it,
and only the key asks. Written into `documents/design.md`.

## Done, 2026-09-20

The code, the migration and the tests are in: `EditEntry` carries `state` and
`askedBy`, `Store.markEditUndone` became `recordPersonAction`, the v8 migration
maps every old row and renames `undoneAt` to `personActedAt`, `Applier` counts
writes and removals apart, and the notice says both. `documents/requirements.md`
gained WORD-1 to WORD-4 and a rewritten NOTICE-1; `documents/design.md` gained
the section describing the two fields and the migration. `deno task check` and
`deno task test` are green, 207 Swift tests where there were 206 — the new one
builds a v7 database holding a row of every old state and asserts the mapping.

Not done, and needing their own go-ahead: build 22, re-rendering the store
screenshots `04-edits.png` and `05-edit.png`, the TestFlight upload, and the
acceptance walk on the new build.

## What this does not change

Nothing about the wire, the archive, the reading path or the applier's reach. No
requirement changes about what an agent may touch. The journal's contents are
preserved; only how a row is written down and read out.

## A second word, decided 2026-09-20

The owner read the finished journal and asked what separates `refused` from `removed`. The answer
exposed the next wrong word: `refused` is the only unhappy outcome of the five, and the word dresses
it up as somebody's decision. Nine of the eleven codes are nothing anybody decided — a metric this
app does not write, a unit that does not fit, a span that cannot be, no such record, a letter that
would not open or would not parse. Two of them genuinely are a decision: Health saying no, and Health
access never granted.

Worse, `declined` sat in the same list meaning "you turned this down", so two different states read
as one word.

Decided: the item is **failed**, everywhere — screen, journal, wire, service, the listing an agent
reads (WORD-5 in `documents/requirements.md`). This is not a new word: the service has always called
a whole edit `failed` when one of its items did not land, so the rename makes the item agree with the
edit rather than inventing a third vocabulary. `refused` stays only where somebody really refused —
the service turning a request away, Apple turning down an attestation, the system turning down a
wake, a day the service keeps rejecting, and the code `healthRefused`.

The owner also asked whether `removed` might be `canceled`. It cannot: `canceled` says an action was
called off and leaves unsaid whether the record is in Health, which is the one question the journal
exists to answer; "cancel" is also what happens *before* an action, and the approval gate that word
belonged to was removed. `removed` is the pair to `written`, and every row answers with one of them.

### Done

`v9.editLog.failedNotRefused` rewrites the stored word. On the wire `Outcome.refused` became
`Outcome.failed`, `Outcome.Refusal` became `Outcome.Failure`, and `WriteRefused` became
`WriteFailed`. The service writes the count under `failed` and reads the old key as well, because an
outcome stored before the rename is a real answer and reading it as zero would report a failed edit
as applied. The screen's field under a record is now "did not happen" rather than "refused", the
strip says "could not write 1 record", and the notice ends "and 1 did not happen".

`deno task check` and `deno task test` are green: 207 Swift tests (206 passed, 1 skipped), 118 on the
protocol and the service, 113 on the Python reader.

Not done, and needing their own go-ahead: build 22 is still the number, because it was never
uploaded anywhere; deploying the service to both environments; re-rendering the store screenshots;
the TestFlight upload; and the acceptance walk.

### The phone and the service change word together (owner, 2026-09-20)

`validateOutcome` turns away a field it does not know, so a phone and a Worker on different sides of
this rename cannot talk: an old phone answering `refused` to a new Worker, or a new phone answering
`failed` to an old one, is turned away either way. The phone has already applied the items by then,
so the edit stays in the queue and is applied again on the next pass, for ever, without its outcome
ever landing.

Decided: **nothing is deployed until the build is ready to go out, and then the Worker deploy and the
build install happen back to back, in one sitting.** No compatibility window is built for this — the
phone and the service are updated together, and a Worker deployed on its own is the mistake this
paragraph exists to prevent. The gap between the two is a few minutes, and it is harmless as long as
no edit is put into the queue during it; the queue is empty and only the owner fills it.
